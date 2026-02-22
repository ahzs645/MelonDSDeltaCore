//
//  MelonDSEmulatorBridge.m
//  MelonDSDeltaCore
//
//  Created by Riley Testut on 10/31/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

#import "MelonDSEmulatorBridge.h"

#import <UIKit/UIKit.h> // Prevent undeclared symbols in below headers

#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>

#if STATIC_LIBRARY
#import "MelonDSDeltaCore-Swift.h"
#import "MelonDSTypes.h"
#else
#import <MelonDSDeltaCore/MelonDSDeltaCore-Swift.h>
#endif

#include "melonDS/src/Platform.h"
#include "melonDS/src/NDS.h"
#include "melonDS/src/SPU.h"
#include "melonDS/src/GPU.h"
#include "melonDS/src/AREngine.h"

#include "melonDS/src/frontend/qt_sdl/Config.h"
#include "melonDS/src/frontend/qt_sdl/LAN_Socket.h"

#include <memory>
#include <vector>
#include <deque>
#include <mutex>
#include <cstdarg>
#include <unistd.h>

#import <notify.h>
#import <pthread.h>

namespace WifiAP
{
extern int ClientStatus;
}

namespace SPI_Firmware
{
extern u8* Firmware;
extern u32 FirmwareLength;
extern u32 FirmwareMask;

extern std::array<u8, 4> DNS;
extern int64_t wfcID;
extern int64_t wfcFlags; // Required to ensure we don't generate invalid WFC ID after erasing WFC configuration
}

// Copied from melonDS source (no longer exists in HEAD)
void ParseTextCode(char* text, int tlen, u32* code, int clen) // or whatever this should be named?
{
    u32 cur_word = 0;
    u32 ndigits = 0;
    u32 nin = 0;
    u32 nout = 0;

    char c;
    while ((c = *text++) != '\0')
    {
        u32 val;
        if (c >= '0' && c <= '9')
            val = c - '0';
        else if (c >= 'a' && c <= 'f')
            val = c - 'a' + 0xA;
        else if (c >= 'A' && c <= 'F')
            val = c - 'A' + 0xA;
        else
            continue;

        cur_word <<= 4;
        cur_word |= val;

        ndigits++;
        if (ndigits >= 8)
        {
            if (nout >= clen)
            {
                printf("AR: code too long!\n");
                return;
            }

            *code++ = cur_word;
            nout++;

            ndigits = 0;
            cur_word = 0;
        }

        nin++;
        if (nin >= tlen) break;
    }

    if (nout & 1)
    {
        printf("AR: code was missing one word\n");
        if (nout >= clen)
        {
            printf("AR: code too long!\n");
            return;
        }
        *code++ = 0;
    }
}

@interface MelonDSEmulatorBridge ()

@property (nonatomic, copy, nullable, readwrite) NSURL *gameURL;
@property (nonatomic, copy, nullable) NSURL *gbaSaveURL;

@property (nonatomic, copy, nullable) NSData *saveData;
@property (nonatomic, copy, nullable) NSData *gbaSaveData;

@property (nonatomic) uint32_t activatedInputs;
@property (nonatomic) CGPoint touchScreenPoint;

@property (nonatomic, readonly) std::shared_ptr<ARCodeFile> cheatCodes;
@property (nonatomic, readonly) int notifyToken;

@property (nonatomic, getter=isInitialized) BOOL initialized;
@property (nonatomic, getter=isStopping) BOOL stopping;
@property (nonatomic, getter=isMicrophoneEnabled) BOOL microphoneEnabled;

@property (nonatomic, nullable) AVAudioEngine *audioEngine;
@property (nonatomic, nullable, readonly) AVAudioConverter *audioConverter; // May be nil while microphone is being used by another app.
@property (nonatomic, readonly) AVAudioUnitEQ *audioEQEffect;
@property (nonatomic, readonly) DLTARingBuffer *microphoneBuffer;
@property (nonatomic, readonly) dispatch_queue_t microphoneQueue;

@property (nonatomic) int closedLidFrameCount;

@end

namespace
{
    NSNotificationName const MelonDSDidProduceMultiplayerPacketNotification = @"MelonDSDidProduceMultiplayerPacketNotification";

    struct MultiplayerPacket
    {
        MelonDSMultiplayerPacketType type;
        uint64_t timestamp;
        std::vector<u8> payload;
    };

    std::mutex sMultiplayerQueueLock;
    std::deque<MultiplayerPacket> sRegularPackets;
    std::deque<MultiplayerPacket> sHostPackets;
    std::deque<MultiplayerPacket> sReplyPackets;
    std::deque<MultiplayerPacket> sAckPackets;

    std::deque<MultiplayerPacket> &QueueForType(MelonDSMultiplayerPacketType type)
    {
        switch (type)
        {
            case MelonDSMultiplayerPacketTypeCommand: return sHostPackets;
            case MelonDSMultiplayerPacketTypeReply: return sReplyPackets;
            case MelonDSMultiplayerPacketTypeAck: return sAckPackets;
            case MelonDSMultiplayerPacketTypeRegular:
            default:
                return sRegularPackets;
        }
    }

    int DequeuePacket(std::deque<MultiplayerPacket> &queue, u8 *data, u64 *timestamp)
    {
        std::lock_guard<std::mutex> lock(sMultiplayerQueueLock);
        if (queue.empty())
        {
            return 0;
        }

        MultiplayerPacket packet = std::move(queue.front());
        queue.pop_front();

        if (timestamp != nullptr)
        {
            *timestamp = packet.timestamp;
        }

        memcpy(data, packet.payload.data(), packet.payload.size());
        return (int)packet.payload.size();
    }
}

@implementation MelonDSEmulatorBridge
@synthesize audioRenderer = _audioRenderer;
@synthesize videoRenderer = _videoRenderer;
@synthesize saveUpdateHandler = _saveUpdateHandler;
@synthesize audioConverter = _audioConverter;

+ (instancetype)sharedBridge
{
    static MelonDSEmulatorBridge *_emulatorBridge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _emulatorBridge = [[self alloc] init];
    });

    return _emulatorBridge;
}

+ (NSNotificationName)didProduceMultiplayerPacketNotification
{
    return MelonDSDidProduceMultiplayerPacketNotification;
}

+ (void)enqueueMultiplayerPacket:(NSData *)packet type:(MelonDSMultiplayerPacketType)type timestamp:(uint64_t)timestamp
{
    if (packet.length == 0)
    {
        return;
    }

    MultiplayerPacket incomingPacket;
    incomingPacket.type = type;
    incomingPacket.timestamp = timestamp;
    incomingPacket.payload.resize(packet.length);
    memcpy(incomingPacket.payload.data(), packet.bytes, packet.length);

    std::lock_guard<std::mutex> lock(sMultiplayerQueueLock);
    QueueForType(type).push_back(std::move(incomingPacket));
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _cheatCodes = std::make_shared<ARCodeFile>("");
        _activatedInputs = 0;

        _audioEQEffect = [[AVAudioUnitEQ alloc] initWithNumberOfBands:2];

        _microphoneBuffer = [[DLTARingBuffer alloc] initWithPreferredBufferSize:100 * 1024];
        _microphoneQueue = dispatch_queue_create("com.rileytestut.MelonDSDeltaCore.Microphone", DISPATCH_QUEUE_SERIAL);

        _closedLidFrameCount = 0;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAudioSessionInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
    }

    return self;
}

#pragma mark - Emulation State -

- (void)startWithGameURL:(NSURL *)gameURL
{
    if (self.wfcDNS != nil)
    {
        NSArray *components = [self.wfcDNS componentsSeparatedByString:@"."];
        if (components.count == 4)
        {
            SPI_Firmware::DNS = { (u8)[components[0] intValue], (u8)[components[1] intValue], (u8)[components[2] intValue], (u8)[components[3] intValue] };
        }
        else
        {
            SPI_Firmware::DNS = { 0, 0, 0, 0 };
        }
    }
    else
    {
        SPI_Firmware::DNS = { 0, 0, 0, 0 };
    }

    int64_t wfcID = [[[NSUserDefaults standardUserDefaults] objectForKey:MelonDSWFCIDUserDefaultsKey] longLongValue];
    int64_t wfcFlags = [[[NSUserDefaults standardUserDefaults] objectForKey:MelonDSWFCFlagsUserDefaultsKey] longLongValue];

    if (wfcID != 0)
    {
        SPI_Firmware::wfcID = wfcID;
        SPI_Firmware::wfcFlags = wfcFlags;
    }
    else
    {
        SPI_Firmware::wfcID = 0;
        SPI_Firmware::wfcFlags = 0;
    }

    self.gameURL = gameURL;

    if ([self isInitialized])
    {
        NDS::DeInit();
    }
    else
    {
        Config::Load();

        Config::FirmwareUsername = "Delta";
        Config::FirmwareBirthdayDay = 7;
        Config::FirmwareBirthdayMonth = 10;

        // DS paths
        Config::BIOS7Path = self.bios7URL.lastPathComponent.UTF8String;
        Config::BIOS9Path = self.bios9URL.lastPathComponent.UTF8String;
        Config::FirmwarePath = self.firmwareURL.lastPathComponent.UTF8String;

        // DSi paths
        Config::DSiBIOS7Path = self.dsiBIOS7URL.lastPathComponent.UTF8String;
        Config::DSiBIOS9Path = self.dsiBIOS9URL.lastPathComponent.UTF8String;
        Config::DSiFirmwarePath = self.dsiFirmwareURL.lastPathComponent.UTF8String;
        Config::DSiNANDPath = self.dsiNANDURL.lastPathComponent.UTF8String;

        [self registerForNotifications];

        // Renderer is not deinitialized in NDS::DeInit, so initialize it only once.
        GPU::InitRenderer(0);
    }

    [self prepareAudioEngine];

    NDS::SetConsoleType((int)self.systemType);

    // AltJIT does not yet support melonDS 0.9.5.
    // Config::JIT_Enable = [self isJITEnabled];
    // Config::JIT_FastMemory = NO;

    if ([[NSFileManager defaultManager] fileExistsAtPath:self.bios7URL.path] &&
        [[NSFileManager defaultManager] fileExistsAtPath:self.bios9URL.path] &&
        [[NSFileManager defaultManager] fileExistsAtPath:self.firmwareURL.path])
    {
        // User has provided BIOS files, so prefer using them.
        Config::ExternalBIOSEnable = true;
    }
    else
    {
        // External BIOS files don't exist, so fall back to internal BIOS.
        Config::ExternalBIOSEnable = false;
    }

    NDS::Init();
    self.initialized = YES;

    GPU::RenderSettings settings;
    settings.Soft_Threaded = YES;

    GPU::SetRenderSettings(0, settings);

    NDS::Reset();
    self.gbaSaveURL = nil;

    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:gameURL.path isDirectory:&isDirectory] && !isDirectory)
    {
        // Game exists and is not a directory.

        NSError *error = nil;
        NSData *romData = [NSData dataWithContentsOfURL:gameURL options:0 error:&error];
        if (romData == nil)
        {
            NSLog(@"Failed to load Nintendo DS ROM. %@", error);
            return;
        }

        if (NDS::LoadCart((const u8 *)romData.bytes, (u32)romData.length, NULL, 0))
        {
            NDS::SetupDirectBoot(gameURL.lastPathComponent.UTF8String);
        }
        else
        {
            NSLog(@"Failed to load Nintendo DS ROM.");
        }

        if (self.gbaGameURL != nil)
        {
            NSData *gbaROMData = [NSData dataWithContentsOfURL:self.gbaGameURL options:0 error:&error];
            if (gbaROMData)
            {
                NSURL *gbaSaveURL = [[self.gbaGameURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"sav"];

                NSData *saveData = [NSData dataWithContentsOfURL:gbaSaveURL options:0 error:&error];
                if (saveData == nil && !([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoSuchFileError))
                {
                    // Ignore "file not found" errors.
                    NSLog(@"Failed to load inserted GBA ROM save data. %@", error);
                }

                if (NDS::LoadGBACart((const u8 *)gbaROMData.bytes, (u32)gbaROMData.length, (const u8 *)saveData.bytes, (u32)saveData.length))
                {
                    // Cache save URL so we don't accidentally overwrite save data for the wrong game when switching.
                    self.gbaSaveURL = gbaSaveURL;
                }
                else
                {
                    NSLog(@"Failed to load inserted GBA ROM");
                }
            }
            else
            {
                NSLog(@"Failed to load inserted GBA ROM. %@", error);
            }
        }
    }
    else
    {
        NDS::LoadBIOS();
    }

    self.stopping = NO;

    NDS::Start();
}

- (void)stop
{
    self.stopping = YES;

    NDS::Stop();

    [self.audioEngine stop];

    // Assign to nil to prevent microphone indicator
    // staying on after returning from background.
    self.audioEngine = nil;
}

- (void)pause
{
    [self.audioEngine pause];
}

- (void)resume
{
}

#pragma mark - Game Loop -

- (void)runFrameAndProcessVideo:(BOOL)processVideo
{
    if ([self isStopping])
    {
        return;
    }

    int previousClientStatus = WifiAP::ClientStatus;

    uint32_t inputs = self.activatedInputs;
    uint32_t inputsMask = 0xFFF; // 0b000000111111111111;

    uint16_t sanitizedInputs = inputsMask ^ inputs;
    NDS::SetKeyMask(sanitizedInputs);

    if (self.activatedInputs & MelonDSGameInputTouchScreenX || self.activatedInputs & MelonDSGameInputTouchScreenY)
    {
        NDS::TouchScreen(self.touchScreenPoint.x, self.touchScreenPoint.y);
    }
    else
    {
        NDS::ReleaseScreen();
    }

    if (self.activatedInputs & MelonDSGameInputLid)
    {
        NDS::SetLidClosed(true);
        self.closedLidFrameCount = 0;
    }
    else if (NDS::IsLidClosed())
    {
        if (self.closedLidFrameCount >= 7) // Derived from quick experiments - 6 is too low for resuming iPad Pro from background non-AirPlay
        {
            NDS::SetLidClosed(false);
            self.closedLidFrameCount = 0;
        }
        else
        {
            self.closedLidFrameCount += 1;
        }
    }

    static int16_t micBuffer[735];
    NSInteger readBytes = (NSInteger)[self.microphoneBuffer readIntoBuffer:micBuffer preferredSize:735 * sizeof(int16_t)];
    NSInteger readFrames = readBytes / sizeof(int16_t);

    if (readFrames > 0)
    {
        NDS::MicInputFrame(micBuffer, (int)readFrames);
    }

    if ([self isJITEnabled])
    {
        // Skipping frames with JIT disabled can cause graphical bugs,
        // so limit frame skip to devices that support JIT (for now).

        // JIT not currently supported with melonDS 0.9.5.
        // NDS::SetSkipFrame(!processVideo);
    }

    NDS::RunFrame();

    static int16_t buffer[0x1000];
    u32 availableBytes = SPU::GetOutputSize();
    availableBytes = MAX(availableBytes, (u32)(sizeof(buffer) / (2 * sizeof(int16_t))));

    int samples = SPU::ReadOutput(buffer, availableBytes);
    [self.audioRenderer.audioBuffer writeBuffer:buffer size:samples * 4];

    if (processVideo)
    {
        int screenBufferSize = 256 * 192 * 4;

        memcpy(self.videoRenderer.videoBuffer, GPU::Framebuffer[GPU::FrontBuffer][0], screenBufferSize);
        memcpy(self.videoRenderer.videoBuffer + screenBufferSize, GPU::Framebuffer[GPU::FrontBuffer][1], screenBufferSize);

        [self.videoRenderer processFrame];
    }

    if (WifiAP::ClientStatus != previousClientStatus)
    {
        if (WifiAP::ClientStatus == 0)
        {
            // Disconnected
            [[NSNotificationCenter defaultCenter] postNotificationName:MelonDSDidDisconnectFromWFCNotification object:self];
        }
        else if (WifiAP::ClientStatus == 2)
        {
            // Connected
            [[NSNotificationCenter defaultCenter] postNotificationName:MelonDSDidConnectToWFCNotification object:self];
        }
    }
}

- (nullable NSData *)readMemoryAtAddress:(NSInteger)address size:(NSInteger)size
{
    if (NDS::MainRAM == NULL)
    {
        return nil;
    }

    if (address + size > 0x1000000)
    {
        // Beyond RAM bounds, return nil.
        return nil;
    }

    void *bytes = (NDS::MainRAM + address);
    NSData *data = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:NO];
    return data;
}

#pragma mark - Inputs -

- (void)activateInput:(NSInteger)input value:(double)value playerIndex:(NSInteger)playerIndex
{
    self.activatedInputs |= (uint32_t)input;

    CGPoint touchPoint = self.touchScreenPoint;

    switch ((MelonDSGameInput)input)
    {
    case MelonDSGameInputTouchScreenX:
        touchPoint.x = value * (256 - 1);
        break;

    case MelonDSGameInputTouchScreenY:
        touchPoint.y = value * (192 - 1);
        break;

    default: break;
    }

    self.touchScreenPoint = touchPoint;
}

- (void)deactivateInput:(NSInteger)input playerIndex:(NSInteger)playerIndex
{
    self.activatedInputs &= ~((uint32_t)input);

    CGPoint touchPoint = self.touchScreenPoint;

    switch ((MelonDSGameInput)input)
    {
        case MelonDSGameInputTouchScreenX:
            touchPoint.x = 0;
            break;

        case MelonDSGameInputTouchScreenY:
            touchPoint.y = 0;
            break;

        default: break;
    }

    self.touchScreenPoint = touchPoint;
}

- (void)resetInputs
{
    self.activatedInputs = 0;
    self.touchScreenPoint = CGPointZero;
}

#pragma mark - Game Saves -

- (void)saveGameSaveToURL:(NSURL *)fileURL
{
    if (self.saveData.length > 0)
    {
        NSError *error = nil;
        if (![self.saveData writeToURL:fileURL options:NSDataWritingAtomic error:&error])
        {
            NSLog(@"Failed write save data. %@", error);
        }
    }

    if (self.gbaSaveURL != nil && self.gbaSaveData.length > 0)
    {
        NSError *error = nil;
        if (![self.gbaSaveData writeToURL:self.gbaSaveURL options:NSDataWritingAtomic error:&error])
        {
            NSLog(@"Failed write GBA save data. %@", error);
        }
    }

    if (SPI_Firmware::Firmware)
    {
        // Save WFC ID to NSUserDefaults

        u32 userdata = 0x7FE00 & SPI_Firmware::FirmwareMask;
        u32 apdata = userdata - 0x400;

        int64_t wfcID = 0;
        int64_t wfcFlags = 0;

        memcpy(&wfcID, &SPI_Firmware::Firmware[apdata + 0xF0], 6);
        memcpy(&wfcFlags, &SPI_Firmware::Firmware[apdata + 0xF6], 8);

        if (wfcID != 0)
        {
            [[NSUserDefaults standardUserDefaults] setObject:@(wfcID) forKey:MelonDSWFCIDUserDefaultsKey];
            [[NSUserDefaults standardUserDefaults] setObject:@(wfcFlags) forKey:MelonDSWFCFlagsUserDefaultsKey];
        }
        else
        {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:MelonDSWFCIDUserDefaultsKey];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:MelonDSWFCFlagsUserDefaultsKey];
        }
    }
}

- (void)loadGameSaveFromURL:(NSURL *)fileURL
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path])
    {
        return;
    }

    NSError *error = nil;
    NSData *saveData = [NSData dataWithContentsOfURL:fileURL options:0 error:&error];
    if (saveData == nil)
    {
        NSLog(@"Failed load save data. %@", error);
        return;
    }

    NDS::LoadSave((const u8 *)saveData.bytes, (u32)saveData.length);
}

#pragma mark - Save States -

- (void)saveSaveStateToURL:(NSURL *)URL
{
    Savestate *savestate = new Savestate(URL.fileSystemRepresentation, true);
    NDS::DoSavestate(savestate);
    delete savestate;
}

- (void)loadSaveStateFromURL:(NSURL *)URL
{
    Savestate *savestate = new Savestate(URL.fileSystemRepresentation, false);
    NDS::DoSavestate(savestate);
    delete savestate;
}

#pragma mark - Cheats -

- (BOOL)addCheatCode:(NSString *)cheatCode type:(NSString *)type
{
    NSArray<NSString *> *codes = [cheatCode componentsSeparatedByString:@"\n"];
    for (NSString *code in codes)
    {
        if (code.length != 17)
        {
            return NO;
        }

        NSMutableCharacterSet *legalCharactersSet = [NSMutableCharacterSet hexadecimalCharacterSet];
        [legalCharactersSet addCharactersInString:@" "];

        if ([code rangeOfCharacterFromSet:legalCharactersSet.invertedSet].location != NSNotFound)
        {
            return NO;
        }
    }

    NSString *sanitizedCode = [[cheatCode componentsSeparatedByCharactersInSet:NSCharacterSet.hexadecimalCharacterSet.invertedSet] componentsJoinedByString:@""];
    u32 codeLength = (u32)(sanitizedCode.length / 8);

    ARCode code;
    code.Name = sanitizedCode.UTF8String;
    ParseTextCode((char *)sanitizedCode.UTF8String, (int)[sanitizedCode lengthOfBytesUsingEncoding:NSUTF8StringEncoding], &code.Code[0], 128);
    code.Enabled = YES;
    code.CodeLen = codeLength;

    ARCodeCat category;
    category.Name = sanitizedCode.UTF8String;
    category.Codes.push_back(code);

    self.cheatCodes->Categories.push_back(category);

    return YES;
}

- (void)resetCheats
{
    self.cheatCodes->Categories.clear();
    AREngine::Reset();
}

- (void)updateCheats
{
    AREngine::SetCodeFile(self.cheatCodes.get());
}

#pragma mark - Notifications -

- (void)registerForNotifications
{
    NSString *privateAPIName = [[@[@"com", @"apple", @"springboard", @"hasBlank3dScr33n"] componentsJoinedByString:@"."] stringByReplacingOccurrencesOfString:@"3" withString:@"e"];

    int status = notify_register_dispatch(privateAPIName.UTF8String, &_notifyToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t state;
        int result = notify_get_state(self.notifyToken, &state);
        NSLog(@"Lock screen state = %llu", state);

        if (state == 0)
        {
            [self deactivateInput:MelonDSGameInputLid playerIndex:0];
        }
        else
        {
            [self activateInput:MelonDSGameInputLid value:1 playerIndex:0];
        }

        if (result != NOTIFY_STATUS_OK)
        {
            NSLog(@"Lock screen notification returned: %d", result);
        }
    });

    if (status != NOTIFY_STATUS_OK)
    {
        NSLog(@"Lock screen notification registration returned: %d", status);
    }
}

#pragma mark - Microphone -

- (void)prepareAudioEngine
{
    self.audioEngine = [[AVAudioEngine alloc] init];
    if ([self.audioEngine.inputNode inputFormatForBus:0].sampleRate == 0)
    {
        // Microphone is being used by another application.
        self.microphoneEnabled = NO;
        return;
    }

    self.microphoneEnabled = YES;

    // Experimentally-determined values. Focuses on ensuring blows are registered correctly.
    self.audioEQEffect.bands[0].filterType = AVAudioUnitEQFilterTypeLowShelf;
    self.audioEQEffect.bands[0].frequency = 100;
    self.audioEQEffect.bands[0].gain = 20;
    self.audioEQEffect.bands[0].bypass = NO;

    self.audioEQEffect.bands[1].filterType = AVAudioUnitEQFilterTypeHighShelf;
    self.audioEQEffect.bands[1].frequency = 10000;
    self.audioEQEffect.bands[1].gain = -30;
    self.audioEQEffect.bands[1].bypass = NO;

    self.audioEQEffect.globalGain = 3;

    [self.audioEngine attachNode:self.audioEQEffect];
    [self.audioEngine connect:self.audioEngine.inputNode to:self.audioEQEffect format:self.audioConverter.inputFormat];

    unsigned int bufferSize = 1024 * self.audioConverter.inputFormat.streamDescription->mBytesPerFrame;
    [self.audioEQEffect installTapOnBus:0 bufferSize:bufferSize format:self.audioConverter.inputFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
        dispatch_async(self.microphoneQueue, ^{
            [self processMicrophoneBuffer:buffer];
        });
    }];
}

- (void)processMicrophoneBuffer:(AVAudioPCMBuffer *)inputBuffer
{
    static AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.audioConverter.outputFormat frameCapacity:5000];
    outputBuffer.frameLength = 5000;

    __block BOOL didReturnBuffer = NO;

    NSError *error = nil;
    AVAudioConverterOutputStatus status = [self.audioConverter convertToBuffer:outputBuffer error:&error
                                                            withInputFromBlock:^AVAudioBuffer * _Nullable(AVAudioPacketCount packetCount, AVAudioConverterInputStatus * _Nonnull outStatus) {
        if (didReturnBuffer)
        {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        else
        {
            didReturnBuffer = YES;
            *outStatus = AVAudioConverterInputStatus_HaveData;
            return inputBuffer;
        }
    }];

    if (status == AVAudioConverterOutputStatus_Error)
    {
        NSLog(@"Conversion error: %@", error);
    }

    NSInteger outputSize = outputBuffer.frameLength * outputBuffer.format.streamDescription->mBytesPerFrame;
    [self.microphoneBuffer writeBuffer:outputBuffer.int16ChannelData[0] size:outputSize];
}

- (void)handleAudioSessionInterruption:(NSNotification *)notification
{
    AVAudioSessionInterruptionType interruptionType = (AVAudioSessionInterruptionType)[notification.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];

    switch (interruptionType)
    {
        case AVAudioSessionInterruptionTypeBegan:
        {
            self.microphoneEnabled = NO;
            break;
        }

        case AVAudioSessionInterruptionTypeEnded:
        {
            if (self.audioEngine)
            {
                // Only reset audio engine if there is currently an active one.
                [self prepareAudioEngine];
            }

            break;
        }
    }
}

#pragma mark - Getters/Setters -

- (NSTimeInterval)frameDuration
{
    return (1.0 / 60.0);
}

- (NSURL *)bios7URL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"bios7.bin"];
}

- (NSURL *)bios9URL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"bios9.bin"];
}

- (NSURL *)firmwareURL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"firmware.bin"];
}

- (NSURL *)dsiBIOS7URL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"dsibios7.bin"];
}

- (NSURL *)dsiBIOS9URL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"dsibios9.bin"];
}

- (NSURL *)dsiFirmwareURL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"dsifirmware.bin"];
}

- (NSURL *)dsiNANDURL
{
    return [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@"dsinand.bin"];
}

- (AVAudioConverter *)audioConverter
{
    if (_audioConverter == nil)
    {
        // Lazily initialize so we don't cause microphone permission alert to appear prematurely.
        AVAudioFormat *inputFormat = [_audioEngine.inputNode inputFormatForBus:0];
        AVAudioFormat *outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:44100 channels:1 interleaved:NO];
        _audioConverter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    }

    return _audioConverter;
}

@end

namespace melonDS::Platform
{
    namespace
    {
        const char *FileModeToString(FileMode mode)
        {
            auto hasFlag = [&](FileMode flag) {
            return (static_cast<unsigned>(mode) & static_cast<unsigned>(flag)) != 0;
        };
        const bool read = hasFlag(FileMode::Read);
        const bool write = hasFlag(FileMode::Write);
        const bool append = hasFlag(FileMode::Append);
        const bool preserve = hasFlag(FileMode::Preserve);
        const bool text = hasFlag(FileMode::Text);

            if (append) return text ? "ab+" : "ab+";
            if (read && write) return (preserve || hasFlag(FileMode::NoCreate)) ? (text ? "r+" : "rb+") : (text ? "w+" : "wb+");
            if (write) return preserve ? (text ? "a" : "ab") : (text ? "w" : "wb");
            return text ? "r" : "rb";
        }

        FILE* AsFILE(FileHandle* file)
        {
            return reinterpret_cast<FILE*>(file);
        }

        FileHandle* AsFileHandle(FILE* file)
        {
            return reinterpret_cast<FileHandle*>(file);
        }
    }

    void SignalStop(StopReason reason, void* userdata)
    {
        (void)reason;
        (void)userdata;
        if ([MelonDSEmulatorBridge.sharedBridge isStopping])
        {
            return;
        }

        MelonDSEmulatorBridge.sharedBridge.stopping = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:DLTAEmulatorCore.emulationDidQuitNotification object:MelonDSEmulatorBridge.sharedBridge];
    }

    std::string GetLocalFilePath(const std::string& filename)
    {
        NSURL *url = [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@(filename.c_str())];
        return std::string(url.fileSystemRepresentation);
    }

    FileHandle* OpenFile(const std::string& path, FileMode mode)
    {
        const char *modeString = FileModeToString(mode);
        FILE *file = fopen(path.c_str(), modeString);
        return AsFileHandle(file);
    }

    FileHandle* OpenLocalFile(const std::string& path, FileMode mode)
    {
        NSURL *relativeURL = [MelonDSEmulatorBridge.coreDirectoryURL URLByAppendingPathComponent:@(path.c_str())];
        NSURL *fileURL = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:relativeURL.path] || path.find(".bak") != std::string::npos)
        {
            fileURL = relativeURL;
        }
        else
        {
            fileURL = [NSURL fileURLWithPath:@(path.c_str())];
        }

        return OpenFile(std::string(fileURL.fileSystemRepresentation), mode);
    }

    bool FileExists(const std::string& name)
    {
        return [[NSFileManager defaultManager] fileExistsAtPath:@(name.c_str())];
    }

    bool LocalFileExists(const std::string& name)
    {
        return FileExists(GetLocalFilePath(name));
    }

    bool CheckFileWritable(const std::string& filepath)
    {
        FileHandle* file = OpenFile(filepath, FileMode::Write | FileMode::Append);
        if (file == nullptr) return false;
        return CloseFile(file);
    }

    bool CheckLocalFileWritable(const std::string& filepath)
    {
        FileHandle* file = OpenLocalFile(filepath, FileMode::Write | FileMode::Append);
        if (file == nullptr) return false;
        return CloseFile(file);
    }

    bool CloseFile(FileHandle* file)
    {
        return file != nullptr && fclose(AsFILE(file)) == 0;
    }

    bool IsEndOfFile(FileHandle* file)
    {
        return file != nullptr && feof(AsFILE(file));
    }

    bool FileReadLine(char* str, int count, FileHandle* file)
    {
        return file != nullptr && fgets(str, count, AsFILE(file)) != nullptr;
    }

    u64 FilePosition(FileHandle* file)
    {
        if (file == nullptr) return 0;
        return (u64)ftell(AsFILE(file));
    }

    bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin)
    {
        if (file == nullptr) return false;

        int whence = SEEK_SET;
        switch (origin)
        {
            case FileSeekOrigin::Start: whence = SEEK_SET; break;
            case FileSeekOrigin::Current: whence = SEEK_CUR; break;
            case FileSeekOrigin::End: whence = SEEK_END; break;
        }

        return fseek(AsFILE(file), (long)offset, whence) == 0;
    }

    void FileRewind(FileHandle* file)
    {
        if (file != nullptr) rewind(AsFILE(file));
    }

    u64 FileRead(void* data, u64 size, u64 count, FileHandle* file)
    {
        if (file == nullptr) return 0;
        return fread(data, (size_t)size, (size_t)count, AsFILE(file));
    }

    bool FileFlush(FileHandle* file)
    {
        return file != nullptr && fflush(AsFILE(file)) == 0;
    }

    u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file)
    {
        if (file == nullptr) return 0;
        return fwrite(data, (size_t)size, (size_t)count, AsFILE(file));
    }

    u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...)
    {
        if (file == nullptr) return 0;

        va_list args;
        va_start(args, fmt);
        int written = vfprintf(AsFILE(file), fmt, args);
        va_end(args);
        return written < 0 ? 0 : (u64)written;
    }

    u64 FileLength(FileHandle* file)
    {
        if (file == nullptr) return 0;

        long pos = ftell(AsFILE(file));
        fseek(AsFILE(file), 0, SEEK_END);
        long len = ftell(AsFILE(file));
        fseek(AsFILE(file), pos, SEEK_SET);
        return len < 0 ? 0 : (u64)len;
    }

    void Log(LogLevel level, const char* fmt, ...)
    {
        (void)level;
        va_list args;
        va_start(args, fmt);
        vprintf(fmt, args);
        va_end(args);
    }

    Thread* Thread_Create(std::function<void()> func)
    {
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            func();
        }];

        thread.name = @"MelonDS - Rendering";
        thread.qualityOfService = NSQualityOfServiceUserInitiated;
        [thread start];
        return (Thread *)CFBridgingRetain(thread);
    }

    void Thread_Free(Thread *thread)
    {
        NSThread *nsThread = (NSThread *)CFBridgingRelease(thread);
        [nsThread cancel];
    }

    void Thread_Wait(Thread *thread)
    {
        NSThread *nsThread = (__bridge NSThread *)thread;
        while (nsThread.isExecuting) { continue; }
    }

    Semaphore *Semaphore_Create()
    {
        dispatch_semaphore_t dispatchSemaphore = dispatch_semaphore_create(0);
        return (Semaphore *)CFBridgingRetain(dispatchSemaphore);
    }

    void Semaphore_Free(Semaphore *semaphore)
    {
        CFRelease(semaphore);
    }

    void Semaphore_Reset(Semaphore *semaphore)
    {
        dispatch_semaphore_t dispatchSemaphore = (__bridge dispatch_semaphore_t)semaphore;
        while (dispatch_semaphore_wait(dispatchSemaphore, DISPATCH_TIME_NOW) == 0) { continue; }
    }

    void Semaphore_Wait(Semaphore *semaphore)
    {
        dispatch_semaphore_t dispatchSemaphore = (__bridge dispatch_semaphore_t)semaphore;
        dispatch_semaphore_wait(dispatchSemaphore, DISPATCH_TIME_FOREVER);
    }

    bool Semaphore_TryWait(Semaphore* sema, int timeout_ms)
    {
        dispatch_semaphore_t dispatchSemaphore = (__bridge dispatch_semaphore_t)sema;
        dispatch_time_t timeout = timeout_ms <= 0 ? DISPATCH_TIME_NOW : dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC);
        return dispatch_semaphore_wait(dispatchSemaphore, timeout) == 0;
    }

    void Semaphore_Post(Semaphore *semaphore, int count)
    {
        dispatch_semaphore_t dispatchSemaphore = (__bridge dispatch_semaphore_t)semaphore;
        for (int i = 0; i < count; i++) { dispatch_semaphore_signal(dispatchSemaphore); }
    }

    Mutex *Mutex_Create()
    {
        pthread_mutex_t *mutex = (pthread_mutex_t *)malloc(sizeof(pthread_mutex_t));
        pthread_mutex_init(mutex, NULL);
        return (Mutex *)mutex;
    }

    void Mutex_Free(Mutex *m)
    {
        pthread_mutex_t *mutex = (pthread_mutex_t *)m;
        pthread_mutex_destroy(mutex);
        free(mutex);
    }

    void Mutex_Lock(Mutex *m)
    {
        pthread_mutex_t *mutex = (pthread_mutex_t *)m;
        pthread_mutex_lock(mutex);
    }

    void Mutex_Unlock(Mutex *m)
    {
        pthread_mutex_t *mutex = (pthread_mutex_t *)m;
        pthread_mutex_unlock(mutex);
    }

    bool Mutex_TryLock(Mutex *m)
    {
        pthread_mutex_t *mutex = (pthread_mutex_t *)m;
        return pthread_mutex_trylock(mutex) == 0;
    }

    void Sleep(u64 usecs)
    {
        usleep((useconds_t)usecs);
    }

    u64 GetMSCount()
    {
        return (u64)(CFAbsoluteTimeGetCurrent() * 1000.0);
    }

    u64 GetUSCount()
    {
        return (u64)(CFAbsoluteTimeGetCurrent() * 1000000.0);
    }

    void WriteNDSSave(const u8* savebytes, u32 savelen, u32 writeoffset, u32 writelen, void* userdata)
    {
        (void)writeoffset;
        (void)writelen;
        (void)userdata;
        MelonDSEmulatorBridge.sharedBridge.saveData = [NSData dataWithBytes:savebytes length:savelen];
    }

    void WriteGBASave(const u8* savebytes, u32 savelen, u32 writeoffset, u32 writelen, void* userdata)
    {
        (void)writeoffset;
        (void)writelen;
        (void)userdata;
        MelonDSEmulatorBridge.sharedBridge.gbaSaveData = [NSData dataWithBytes:savebytes length:savelen];
    }

    void WriteFirmware(const Firmware& firmware, u32 writeoffset, u32 writelen, void* userdata)
    {
        (void)firmware;
        (void)writeoffset;
        (void)writelen;
        (void)userdata;
    }

    void WriteDateTime(int year, int month, int day, int hour, int minute, int second, void* userdata)
    {
        (void)year; (void)month; (void)day; (void)hour; (void)minute; (void)second; (void)userdata;
    }

    void MP_Begin(void* userdata)
    {
        (void)userdata;
        std::lock_guard<std::mutex> lock(sMultiplayerQueueLock);
        sRegularPackets.clear();
        sHostPackets.clear();
        sReplyPackets.clear();
        sAckPackets.clear();
    }

    void MP_End(void* userdata)
    {
        (void)userdata;
        std::lock_guard<std::mutex> lock(sMultiplayerQueueLock);
        sRegularPackets.clear();
        sHostPackets.clear();
        sReplyPackets.clear();
        sAckPackets.clear();
    }

    static int PublishMultiplayerPacket(u8* data, int len, u64 timestamp, MelonDSMultiplayerPacketType type)
    {
        if (len <= 0) return 0;
        NSData *packet = [NSData dataWithBytes:data length:len];
        NSDictionary *userInfo = @{@"packet": packet, @"type": @(type), @"timestamp": @(timestamp)};
        [[NSNotificationCenter defaultCenter] postNotificationName:MelonDSEmulatorBridge.didProduceMultiplayerPacketNotification object:MelonDSEmulatorBridge.sharedBridge userInfo:userInfo];
        return len;
    }

    int MP_SendPacket(u8* data, int len, u64 timestamp, void* userdata)
    {
        (void)userdata;
        return PublishMultiplayerPacket(data, len, timestamp, MelonDSMultiplayerPacketTypeRegular);
    }

    int MP_RecvPacket(u8* data, u64* timestamp, void* userdata)
    {
        (void)userdata;
        return DequeuePacket(sRegularPackets, data, timestamp);
    }

    int MP_SendCmd(u8* data, int len, u64 timestamp, void* userdata)
    {
        (void)userdata;
        return PublishMultiplayerPacket(data, len, timestamp, MelonDSMultiplayerPacketTypeCommand);
    }

    int MP_SendReply(u8* data, int len, u64 timestamp, u16 aid, void* userdata)
    {
        (void)aid;
        (void)userdata;
        return PublishMultiplayerPacket(data, len, timestamp, MelonDSMultiplayerPacketTypeReply);
    }

    int MP_SendAck(u8* data, int len, u64 timestamp, void* userdata)
    {
        (void)userdata;
        return PublishMultiplayerPacket(data, len, timestamp, MelonDSMultiplayerPacketTypeAck);
    }

    int MP_RecvHostPacket(u8* data, u64* timestamp, void* userdata)
    {
        (void)userdata;
        return DequeuePacket(sHostPackets, data, timestamp);
    }

    u16 MP_RecvReplies(u8* data, u64 timestamp, u16 aidmask, void* userdata)
    {
        (void)timestamp;
        (void)userdata;
        int len = DequeuePacket(sReplyPackets, data, nullptr);
        return len > 0 ? aidmask : 0;
    }

    int Net_SendPacket(u8* data, int len, void* userdata)
    {
        (void)userdata;
        if (![[MelonDSEmulatorBridge sharedBridge] isWFCEnabled]) return 0;
        return LAN_Socket::SendPacket(data, len);
    }

    int Net_RecvPacket(u8* data, void* userdata)
    {
        (void)userdata;
        if (![[MelonDSEmulatorBridge sharedBridge] isWFCEnabled]) return 0;
        return LAN_Socket::RecvPacket(data);
    }

    void Camera_Start(int num, void* userdata) { (void)num; (void)userdata; }
    void Camera_Stop(int num, void* userdata) { (void)num; (void)userdata; }
    void Camera_CaptureFrame(int num, u32* frame, int width, int height, bool yuv, void* userdata)
    {
        (void)num; (void)frame; (void)width; (void)height; (void)yuv; (void)userdata;
    }

    void Mic_Start(void* userdata)
    {
        (void)userdata;
        if (![MelonDSEmulatorBridge.sharedBridge isMicrophoneEnabled] || [MelonDSEmulatorBridge.sharedBridge.audioEngine isRunning]) return;
        NSError *error = nil;
        if (![MelonDSEmulatorBridge.sharedBridge.audioEngine startAndReturnError:&error])
        {
            NSLog(@"Failed to start listening to microphone. %@", error);
        }
    }

    void Mic_Stop(void* userdata)
    {
        (void)userdata;
        [MelonDSEmulatorBridge.sharedBridge.audioEngine stop];
    }

    int Mic_ReadInput(s16* data, int maxlength, void* userdata)
    {
        (void)userdata;
        NSInteger readBytes = [MelonDSEmulatorBridge.sharedBridge.microphoneBuffer readIntoBuffer:data preferredSize:maxlength * (int)sizeof(int16_t)];
        return (int)(readBytes / (NSInteger)sizeof(int16_t));
    }

    AACDecoder* AAC_Init() { return nullptr; }
    void AAC_DeInit(AACDecoder* dec) { (void)dec; }
    bool AAC_Configure(AACDecoder* dec, int frequency, int channels) { (void)dec; (void)frequency; (void)channels; return false; }
    bool AAC_DecodeFrame(AACDecoder* dec, const void* input, int inputlen, void* output, int outputlen)
    {
        (void)dec; (void)input; (void)inputlen; (void)output; (void)outputlen; return false;
    }

    bool Addon_KeyDown(KeyType type, void* userdata) { (void)type; (void)userdata; return false; }
    void Addon_RumbleStart(u32 len, void* userdata) { (void)len; (void)userdata; }
    void Addon_RumbleStop(void* userdata) { (void)userdata; }
    float Addon_MotionQuery(MotionQueryType type, void* userdata) { (void)type; (void)userdata; return 0.0f; }

    DynamicLibrary* DynamicLibrary_Load(const char* lib) { (void)lib; return nullptr; }
    void DynamicLibrary_Unload(DynamicLibrary* lib) { (void)lib; }
    void* DynamicLibrary_LoadFunction(DynamicLibrary* lib, const char* name) { (void)lib; (void)name; return nullptr; }
}
