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
#include "melonDS/src/Args.h"
#include "melonDS/src/NDS.h"
#include "melonDS/src/DSi.h"
#include "melonDS/src/SPU.h"
#include "melonDS/src/GPU.h"
#include "melonDS/src/AREngine.h"
#include "melonDS/src/NDSCart.h"
#include "melonDS/src/GBACart.h"
#include "melonDS/src/GPU3D_Soft.h"
#include "melonDS/src/version.h"

#include "melonDS/src/frontend/qt_sdl/Config.h"

#include <memory>
#include <optional>
#include <vector>
#include <deque>
#include <mutex>
#include <algorithm>
#include <cstdarg>
#include <unistd.h>

#import <notify.h>
#import <pthread.h>

using namespace melonDS;

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
        uint16_t aid;
        uint64_t timestamp;
        std::vector<u8> payload;
    };

    std::mutex sMultiplayerQueueLock;
    std::deque<MultiplayerPacket> sRegularPackets;
    std::deque<MultiplayerPacket> sHostPackets;
    std::deque<MultiplayerPacket> sReplyPackets;

    std::deque<MultiplayerPacket> &QueueForType(MelonDSMultiplayerPacketType type)
    {
        switch (type)
        {
            case MelonDSMultiplayerPacketTypeCommand: return sHostPackets;
            case MelonDSMultiplayerPacketTypeReply: return sReplyPackets;
            case MelonDSMultiplayerPacketTypeAck: return sHostPackets;
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

    u16 DequeueReplies(u8 *data, u64 timestamp, u16 aidmask)
    {
        std::lock_guard<std::mutex> lock(sMultiplayerQueueLock);
        if (sReplyPackets.empty())
        {
            return 0;
        }

        u16 receivedMask = 0;

        while (!sReplyPackets.empty())
        {
            MultiplayerPacket packet = std::move(sReplyPackets.front());
            sReplyPackets.pop_front();

            if (packet.payload.empty())
            {
                continue;
            }

            // Mirror LocalMP behavior by dropping stale replies.
            if (packet.timestamp < timestamp && (timestamp - packet.timestamp) > 32)
            {
                continue;
            }

            u16 aid = packet.aid;
            if (aid == 0 || aid >= 16)
            {
                continue;
            }

            size_t offset = (size_t)(aid - 1) * 1024;
            size_t copyLength = std::min(packet.payload.size(), (size_t)1024);
            memcpy(data + offset, packet.payload.data(), copyLength);
            receivedMask |= (1 << aid);

            if ((receivedMask & aidmask) == aidmask)
            {
                break;
            }
        }

        return receivedMask;
    }

    std::unique_ptr<melonDS::NDS> sNDSInstance;

    template <typename TImage>
    std::unique_ptr<TImage> LoadFixedImage(NSURL *url, NSString *name)
    {
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
        if (data == nil)
        {
            NSLog(@"Failed to load %@. %@", name, error);
            return nullptr;
        }

        if (data.length != sizeof(TImage))
        {
            NSLog(@"Invalid %@ size: %zu (expected %zu).", name, (size_t)data.length, sizeof(TImage));
            return nullptr;
        }

        auto image = std::make_unique<TImage>();
        memcpy(image->data(), data.bytes, sizeof(TImage));
        return image;
    }

    std::optional<melonDS::Firmware> LoadFirmwareImage(NSURL *url, NSString *name)
    {
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
        if (data == nil)
        {
            NSLog(@"Failed to load %@. %@", name, error);
            return std::nullopt;
        }

        melonDS::Firmware firmware((const u8 *)data.bytes, (u32)data.length);
        if (firmware.Buffer() == nullptr)
        {
            NSLog(@"Invalid %@ image.", name);
            return std::nullopt;
        }

        return firmware;
    }

    std::optional<melonDS::DSi_NAND::NANDImage> LoadDSiNANDImage(NSURL *url, const melonDS::DSiBIOSImage &arm7iBIOS)
    {
        std::string path = std::string(url.fileSystemRepresentation);
        Platform::FileHandle *file = Platform::OpenFile(path, Platform::FileMode::ReadWriteExisting);
        if (file == nullptr)
        {
            NSLog(@"Failed to open DSi NAND at %@.", url.path);
            return std::nullopt;
        }

        melonDS::DSi_NAND::NANDImage nandImage(file, &arm7iBIOS[0x8308]);
        if (!nandImage)
        {
            NSLog(@"Failed to parse DSi NAND image.");
            return std::nullopt;
        }

        return std::optional<melonDS::DSi_NAND::NANDImage>(std::move(nandImage));
    }

    std::unique_ptr<melonDS::NDS> CreateConsole(MelonDSEmulatorBridge *bridge, bool useExternalBIOS)
    {
        melonDS::NDSArgs ndsArgs;
        ndsArgs.JIT = std::nullopt;
        ndsArgs.OutputSampleRate = 32768.0;
        ndsArgs.Renderer3D = std::make_unique<melonDS::SoftRenderer>();

        if (useExternalBIOS)
        {
            auto arm9BIOS = LoadFixedImage<melonDS::ARM9BIOSImage>(bridge.bios9URL, @"DS ARM9 BIOS");
            auto arm7BIOS = LoadFixedImage<melonDS::ARM7BIOSImage>(bridge.bios7URL, @"DS ARM7 BIOS");
            auto dsFirmware = LoadFirmwareImage(bridge.firmwareURL, @"DS firmware");
            if (arm9BIOS == nullptr || arm7BIOS == nullptr || !dsFirmware.has_value())
            {
                return nullptr;
            }

            ndsArgs.ARM9BIOS = std::move(arm9BIOS);
            ndsArgs.ARM7BIOS = std::move(arm7BIOS);
            ndsArgs.Firmware = std::move(*dsFirmware);
        }
        else
        {
            // Fall back to generated firmware + FreeBIOS if external assets are unavailable.
            ndsArgs.Firmware = melonDS::Firmware(0);
        }

        if (bridge.systemType == MelonDSSystemTypeDSi)
        {
            auto arm9iBIOS = LoadFixedImage<melonDS::DSiBIOSImage>(bridge.dsiBIOS9URL, @"DSi ARM9 BIOS");
            auto arm7iBIOS = LoadFixedImage<melonDS::DSiBIOSImage>(bridge.dsiBIOS7URL, @"DSi ARM7 BIOS");
            auto dsiFirmware = LoadFirmwareImage(bridge.dsiFirmwareURL, @"DSi firmware");
            if (arm9iBIOS == nullptr || arm7iBIOS == nullptr || !dsiFirmware.has_value())
            {
                return nullptr;
            }

            auto nandImage = LoadDSiNANDImage(bridge.dsiNANDURL, *arm7iBIOS);
            if (!nandImage.has_value())
            {
                return nullptr;
            }

            ndsArgs.Firmware = std::move(*dsiFirmware);

            melonDS::DSiArgs dsiArgs {
                std::move(ndsArgs),
                std::move(arm9iBIOS),
                std::move(arm7iBIOS),
                std::move(*nandImage),
                std::nullopt,
                false,
                false,
            };
            return std::make_unique<melonDS::DSi>(std::move(dsiArgs), (__bridge void *)bridge);
        }

        return std::make_unique<melonDS::NDS>(std::move(ndsArgs), (__bridge void *)bridge);
    }

    melonDS::NDS *CurrentNDS()
    {
        return sNDSInstance.get();
    }

    void SetCurrentNDS(std::unique_ptr<melonDS::NDS> nds)
    {
        sNDSInstance = std::move(nds);
    }

    void ConfigureRenderer(melonDS::NDS &nds)
    {
        if (auto *renderer = dynamic_cast<melonDS::SoftRenderer *>(&nds.GetRenderer3D()))
        {
            renderer->SetThreaded(true, nds.GPU);
        }
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

+ (NSString *)melonDSVersion
{
    return @(MELONDS_VERSION);
}

+ (NSNotificationName)didProduceMultiplayerPacketNotification
{
    return MelonDSDidProduceMultiplayerPacketNotification;
}

+ (void)enqueueMultiplayerPacket:(NSData *)packet type:(MelonDSMultiplayerPacketType)type timestamp:(uint64_t)timestamp
{
    [self enqueueMultiplayerPacket:packet type:type timestamp:timestamp aid:0];
}

+ (void)enqueueMultiplayerPacket:(NSData *)packet type:(MelonDSMultiplayerPacketType)type timestamp:(uint64_t)timestamp aid:(uint16_t)aid
{
    if (packet.length == 0)
    {
        return;
    }

    MultiplayerPacket incomingPacket;
    incomingPacket.type = type;
    incomingPacket.aid = aid;
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
    self.gameURL = gameURL;

    Config::Load();

    Config::Table globalConfig = Config::GetGlobalTable();
    globalConfig.SetString("Firmware.Username", "Delta");
    globalConfig.SetInt("Firmware.BirthdayDay", 7);
    globalConfig.SetInt("Firmware.BirthdayMonth", 10);

    globalConfig.SetString("DS.BIOS7Path", self.bios7URL.lastPathComponent.UTF8String);
    globalConfig.SetString("DS.BIOS9Path", self.bios9URL.lastPathComponent.UTF8String);
    globalConfig.SetString("DS.FirmwarePath", self.firmwareURL.lastPathComponent.UTF8String);

    globalConfig.SetString("DSi.BIOS7Path", self.dsiBIOS7URL.lastPathComponent.UTF8String);
    globalConfig.SetString("DSi.BIOS9Path", self.dsiBIOS9URL.lastPathComponent.UTF8String);
    globalConfig.SetString("DSi.FirmwarePath", self.dsiFirmwareURL.lastPathComponent.UTF8String);
    globalConfig.SetString("DSi.NANDPath", self.dsiNANDURL.lastPathComponent.UTF8String);

    bool hasExternalDSBIOS = [[NSFileManager defaultManager] fileExistsAtPath:self.bios7URL.path] &&
                             [[NSFileManager defaultManager] fileExistsAtPath:self.bios9URL.path] &&
                             [[NSFileManager defaultManager] fileExistsAtPath:self.firmwareURL.path];
    globalConfig.SetBool("Emu.ExternalBIOSEnable", hasExternalDSBIOS);
    globalConfig.SetInt("Emu.ConsoleType", (int)self.systemType);

    if (![self isInitialized])
    {
        [self registerForNotifications];
    }

    if (melonDS::NDS *existingConsole = CurrentNDS())
    {
        BOOL wasStopping = self.stopping;
        self.stopping = YES;
        if (existingConsole->IsRunning())
        {
            existingConsole->Stop();
        }
        self.stopping = wasStopping;
    }
    SetCurrentNDS(nullptr);

    std::unique_ptr<melonDS::NDS> console = CreateConsole(self, hasExternalDSBIOS);
    if (console == nullptr)
    {
        self.initialized = NO;
        NSLog(@"Failed to initialize melonDS console instance.");
        return;
    }

    SetCurrentNDS(std::move(console));
    melonDS::NDS *nds = CurrentNDS();
    if (nds == nullptr)
    {
        self.initialized = NO;
        NSLog(@"Failed to initialize melonDS console instance.");
        return;
    }

    ConfigureRenderer(*nds);

    [self prepareAudioEngine];

    nds->Reset();
    self.initialized = YES;
    self.saveData = nil;
    self.gbaSaveData = nil;
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

        auto ndsCart = melonDS::NDSCart::ParseROM((const u8 *)romData.bytes, (u32)romData.length, (__bridge void *)self);
        if (ndsCart != nullptr)
        {
            nds->SetNDSCart(std::move(ndsCart));
            nds->SetupDirectBoot(gameURL.lastPathComponent.UTF8String);
        }
        else
        {
            NSLog(@"Failed to load Nintendo DS ROM.");
        }

        if (self.gbaGameURL != nil && nds->ConsoleType == MelonDSSystemTypeDS)
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

                const u8 *saveBytes = (const u8 *)saveData.bytes;
                u32 saveLength = (u32)saveData.length;
                auto gbaCart = melonDS::GBACart::ParseROM((const u8 *)gbaROMData.bytes, (u32)gbaROMData.length, saveBytes, saveLength, (__bridge void *)self);
                if (gbaCart != nullptr)
                {
                    nds->SetGBACart(std::move(gbaCart));
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
        nds->LoadBIOS();
    }

    self.stopping = NO;

    nds->Start();
}

- (void)stop
{
    self.stopping = YES;

    if (melonDS::NDS *nds = CurrentNDS())
    {
        nds->Stop();
    }

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

    melonDS::NDS *nds = CurrentNDS();
    if (nds == nullptr)
    {
        return;
    }

    uint32_t inputs = self.activatedInputs;
    uint32_t inputsMask = 0xFFF; // 0b000000111111111111;

    uint16_t sanitizedInputs = inputsMask ^ inputs;
    nds->SetKeyMask(sanitizedInputs);

    if (self.activatedInputs & MelonDSGameInputTouchScreenX || self.activatedInputs & MelonDSGameInputTouchScreenY)
    {
        nds->TouchScreen(self.touchScreenPoint.x, self.touchScreenPoint.y);
    }
    else
    {
        nds->ReleaseScreen();
    }

    if (self.activatedInputs & MelonDSGameInputLid)
    {
        nds->SetLidClosed(true);
        self.closedLidFrameCount = 0;
    }
    else if (nds->IsLidClosed())
    {
        if (self.closedLidFrameCount >= 7) // Derived from quick experiments - 6 is too low for resuming iPad Pro from background non-AirPlay
        {
            nds->SetLidClosed(false);
            self.closedLidFrameCount = 0;
        }
        else
        {
            self.closedLidFrameCount += 1;
        }
    }

    if ([self isJITEnabled])
    {
        // Skipping frames with JIT disabled can cause graphical bugs,
        // so limit frame skip to devices that support JIT (for now).

        // JIT not currently supported with melonDS in Delta.
        // NDS::SetSkipFrame(!processVideo);
    }

    nds->RunFrame();

    static int16_t buffer[0x1000];
    u32 availableSamples = (u32)nds->SPU.GetOutputSize();
    availableSamples = MAX(availableSamples, (u32)(sizeof(buffer) / (2 * sizeof(int16_t))));

    int samples = nds->SPU.ReadOutput(buffer, (int)availableSamples);
    [self.audioRenderer.audioBuffer writeBuffer:buffer size:samples * 4];

    if (processVideo)
    {
        int screenBufferSize = 256 * 192 * 4;

        memcpy(self.videoRenderer.videoBuffer, nds->GPU.Framebuffer[nds->GPU.FrontBuffer][0].get(), screenBufferSize);
        memcpy(self.videoRenderer.videoBuffer + screenBufferSize, nds->GPU.Framebuffer[nds->GPU.FrontBuffer][1].get(), screenBufferSize);

        [self.videoRenderer processFrame];
    }
}

- (nullable NSData *)readMemoryAtAddress:(NSInteger)address size:(NSInteger)size
{
    melonDS::NDS *nds = CurrentNDS();
    if (nds == nullptr || nds->MainRAM == nullptr)
    {
        return nil;
    }

    if (address + size > (NSInteger)nds->MainRAMMaxSize)
    {
        // Beyond RAM bounds, return nil.
        return nil;
    }

    void *bytes = (nds->MainRAM + address);
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

    if (melonDS::NDS *nds = CurrentNDS())
    {
        nds->SetNDSSave((const u8 *)saveData.bytes, (u32)saveData.length);
        self.saveData = saveData;
    }
}

#pragma mark - Save States -

- (void)saveSaveStateToURL:(NSURL *)URL
{
    melonDS::NDS *nds = CurrentNDS();
    if (nds == nullptr)
    {
        return;
    }

    melonDS::Savestate savestate;
    if (!nds->DoSavestate(&savestate) || savestate.Error)
    {
        NSLog(@"Failed to create save state.");
        return;
    }

    NSData *data = [NSData dataWithBytes:savestate.Buffer() length:savestate.Length()];
    NSError *error = nil;
    if (![data writeToURL:URL options:NSDataWritingAtomic error:&error])
    {
        NSLog(@"Failed write save state. %@", error);
    }
}

- (void)loadSaveStateFromURL:(NSURL *)URL
{
    melonDS::NDS *nds = CurrentNDS();
    if (nds == nullptr)
    {
        return;
    }

    NSError *error = nil;
    NSMutableData *data = [NSMutableData dataWithContentsOfURL:URL options:0 error:&error];
    if (data == nil)
    {
        NSLog(@"Failed load save state. %@", error);
        return;
    }

    melonDS::Savestate savestate(data.mutableBytes, (u32)data.length, false);
    if (!nds->DoSavestate(&savestate) || savestate.Error)
    {
        NSLog(@"Failed to load save state.");
    }
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

    ARCode code {};
    code.Parent = &self.cheatCodes->RootCat;
    code.Name = sanitizedCode.UTF8String;
    code.Description = "";
    code.Enabled = YES;
    code.Code.resize(codeLength);

    if (codeLength > 0)
    {
        ParseTextCode((char *)sanitizedCode.UTF8String, (int)[sanitizedCode lengthOfBytesUsingEncoding:NSUTF8StringEncoding], code.Code.data(), (int)codeLength);
    }
    self.cheatCodes->RootCat.Children.emplace_back(std::move(code));

    return YES;
}

- (void)resetCheats
{
    self.cheatCodes->RootCat.Children.clear();
    if (melonDS::NDS *nds = CurrentNDS())
    {
        nds->AREngine.Cheats.clear();
    }
}

- (void)updateCheats
{
    if (melonDS::NDS *nds = CurrentNDS())
    {
        nds->AREngine.Cheats = self.cheatCodes->GetCodes();
    }
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
        FileHandle* file = OpenFile(filepath, static_cast<FileMode>(FileMode::Write | FileMode::Append));
        if (file == nullptr) return false;
        return CloseFile(file);
    }

    bool CheckLocalFileWritable(const std::string& filepath)
    {
        FileHandle* file = OpenLocalFile(filepath, static_cast<FileMode>(FileMode::Write | FileMode::Append));
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
    }

    void MP_End(void* userdata)
    {
        (void)userdata;
        std::lock_guard<std::mutex> lock(sMultiplayerQueueLock);
        sRegularPackets.clear();
        sHostPackets.clear();
        sReplyPackets.clear();
    }

    static int PublishMultiplayerPacket(u8* data, int len, u64 timestamp, MelonDSMultiplayerPacketType type, u16 aid)
    {
        if (len <= 0) return 0;
        NSData *packet = [NSData dataWithBytes:data length:len];
        NSDictionary *userInfo = @{@"packet": packet, @"type": @(type), @"timestamp": @(timestamp), @"aid": @(aid)};
        [[NSNotificationCenter defaultCenter] postNotificationName:MelonDSEmulatorBridge.didProduceMultiplayerPacketNotification object:MelonDSEmulatorBridge.sharedBridge userInfo:userInfo];
        return len;
    }

    int MP_SendPacket(u8* data, int len, u64 timestamp, void* userdata)
    {
        (void)userdata;
        return PublishMultiplayerPacket(data, len, timestamp, MelonDSMultiplayerPacketTypeRegular, 0);
    }

    int MP_RecvPacket(u8* data, u64* timestamp, void* userdata)
    {
        (void)userdata;
        return DequeuePacket(sRegularPackets, data, timestamp);
    }

    int MP_SendCmd(u8* data, int len, u64 timestamp, void* userdata)
    {
        (void)userdata;
        return PublishMultiplayerPacket(data, len, timestamp, MelonDSMultiplayerPacketTypeCommand, 0);
    }

    int MP_SendReply(u8* data, int len, u64 timestamp, u16 aid, void* userdata)
    {
        (void)userdata;
        return PublishMultiplayerPacket(data, len, timestamp, MelonDSMultiplayerPacketTypeReply, aid);
    }

    int MP_SendAck(u8* data, int len, u64 timestamp, void* userdata)
    {
        (void)userdata;
        return PublishMultiplayerPacket(data, len, timestamp, MelonDSMultiplayerPacketTypeAck, 0);
    }

    int MP_RecvHostPacket(u8* data, u64* timestamp, void* userdata)
    {
        (void)userdata;
        return DequeuePacket(sHostPackets, data, timestamp);
    }

    u16 MP_RecvReplies(u8* data, u64 timestamp, u16 aidmask, void* userdata)
    {
        (void)userdata;
        return DequeueReplies(data, timestamp, aidmask);
    }

    int Net_SendPacket(u8* data, int len, void* userdata)
    {
        (void)data;
        (void)len;
        (void)userdata;
        if (![[MelonDSEmulatorBridge sharedBridge] isWFCEnabled]) return 0;
        return 0;
    }

    int Net_RecvPacket(u8* data, void* userdata)
    {
        (void)data;
        (void)userdata;
        if (![[MelonDSEmulatorBridge sharedBridge] isWFCEnabled]) return 0;
        return 0;
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
