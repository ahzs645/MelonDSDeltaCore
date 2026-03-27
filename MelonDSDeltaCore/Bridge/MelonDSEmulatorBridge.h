//
//  MelonDSEmulatorBridge.h
//  MelonDSDeltaCore
//
//  Created by Riley Testut on 10/31/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol DLTAEmulatorBridging;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MelonDSSystemType)
{
    MelonDSSystemTypeDS NS_SWIFT_NAME(ds) = 0,
    MelonDSSystemTypeDSi NS_SWIFT_NAME(dsi) = 1
};

// MARK: - Local Multiplayer Bridging
// Multiplayer packet types used by melonDS MP_* callbacks.
typedef NS_ENUM(NSInteger, MelonDSMultiplayerPacketType)
{
    MelonDSMultiplayerPacketTypeRegular = 0,
    MelonDSMultiplayerPacketTypeCommand = 1,
    MelonDSMultiplayerPacketTypeReply = 2,
    MelonDSMultiplayerPacketTypeAck = 3,
};


#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything" // Silence "Cannot find protocol definition" warning due to forward declaration.
@interface MelonDSEmulatorBridge : NSObject <DLTAEmulatorBridging>
#pragma clang diagnostic pop

@property (class, nonatomic, readonly) MelonDSEmulatorBridge *sharedBridge;
@property (class, nonatomic, readonly) NSString *melonDSVersion;

@property (nonatomic) MelonDSSystemType systemType;
@property (nonatomic, getter=isJITEnabled) BOOL jitEnabled;
@property (nonatomic, getter=isWFCEnabled) BOOL wfcEnabled;

@property (nonatomic, readonly) NSURL *bios7URL;
@property (nonatomic, readonly) NSURL *bios9URL;
@property (nonatomic, readonly) NSURL *firmwareURL;

@property (nonatomic, readonly) NSURL *dsiBIOS7URL;
@property (nonatomic, readonly) NSURL *dsiBIOS9URL;
@property (nonatomic, readonly) NSURL *dsiFirmwareURL;
@property (nonatomic, readonly) NSURL *dsiNANDURL;

@property (nonatomic, copy, nullable) NSURL *gbaGameURL;
@property (nonatomic, copy, nullable) NSString *wfcDNS;


/// Posted whenever melonDS emits an outbound multiplayer packet.
/// userInfo keys:
/// - @"packet": NSData
/// - @"type": NSNumber (MelonDSMultiplayerPacketType)
/// - @"timestamp": NSNumber (uint64)
/// - @"aid": NSNumber (uint16, only meaningful for MelonDSMultiplayerPacketTypeReply)
@property (class, nonatomic, readonly) NSNotificationName didProduceMultiplayerPacketNotification;
/// Posted whenever melonDS starts a new local wireless session.
@property (class, nonatomic, readonly) NSNotificationName didBeginMultiplayerSessionNotification;
/// Posted whenever melonDS ends the current local wireless session.
@property (class, nonatomic, readonly) NSNotificationName didEndMultiplayerSessionNotification;

/// Enqueues an inbound multiplayer packet for consumption by melonDS MP_Recv* callbacks.
+ (void)enqueueMultiplayerPacket:(NSData *)packet type:(MelonDSMultiplayerPacketType)type timestamp:(uint64_t)timestamp;
+ (void)enqueueMultiplayerPacket:(NSData *)packet type:(MelonDSMultiplayerPacketType)type timestamp:(uint64_t)timestamp aid:(uint16_t)aid;
+ (void)enqueueMultiplayerPacket:(NSData *)packet type:(MelonDSMultiplayerPacketType)type timestamp:(uint64_t)timestamp aid:(uint16_t)aid senderID:(uint32_t)senderID;

/// Updates the number of remote peers currently expected to answer multiplayer reply polls.
+ (void)setExpectedRemotePeerCount:(uint16_t)count;

@end

NS_ASSUME_NONNULL_END
