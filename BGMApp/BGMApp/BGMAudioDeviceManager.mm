// This file is part of Background Music.
//
// Background Music is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation, either version 2 of the
// License, or (at your option) any later version.
//
// Background Music is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Background Music. If not, see <http://www.gnu.org/licenses/>.

//
//  BGMAudioDeviceManager.mm
//  BGMApp
//
//  Copyright © 2016, 2017 Kyle Neideck
//

// Self Include
#import "BGMAudioDeviceManager.h"

// Local Includes
#import "BGM_Types.h"
#import "BGM_Utils.h"
#import "BGMDeviceControlSync.h"
#import "BGMPlayThrough.h"
#import "BGMAudioDevice.h"
#import "BGMXPCProtocols.h"
#import "BGMOutputVolumeMenuItem.h"

// PublicUtility Includes
#import "CAHALAudioSystemObject.h"
#import "CAAutoDisposer.h"


#pragma clang assume_nonnull begin

@implementation BGMAudioDeviceManager {
    BGMBackgroundMusicDevice bgmDevice;
    BGMAudioDevice outputDevice;
    
    BGMDeviceControlSync deviceControlSync;
    BGMPlayThrough playThrough;
    BGMPlayThrough playThrough_UISounds;

    // A connection to BGMXPCHelper so we can send it the ID of the output device.
    NSXPCConnection* __nullable bgmXPCHelperConnection;

    BGMOutputVolumeMenuItem* __nullable outputVolumeMenuItem;

    NSRecursiveLock* stateLock;
}

#pragma mark Construction/Destruction

- (instancetype) initWithError:(NSError** __nullable)error {
    if ((self = [super init])) {
        stateLock = [NSRecursiveLock new];
        bgmXPCHelperConnection = nil;
        outputVolumeMenuItem = nil;

        try {
            bgmDevice = BGMBackgroundMusicDevice();
        } catch (const CAException& e) {
            LogError("BGMAudioDeviceManager::initWithError: BGMDevice not found. (%d)", e.GetError());
            
            if (error) {
                *error = [NSError errorWithDomain:@kBGMAppBundleID code:kBGMErrorCode_BGMDeviceNotFound userInfo:nil];
            }
            
            self = nil;
            return self;
        }

        try {
            [self initOutputDevice];
        } catch (const CAException& e) {
            LogError("BGMAudioDeviceManager::initWithError: failed to init output device (%d)",
                     e.GetError());
            outputDevice.SetObjectID(kAudioObjectUnknown);
        }
        
        if (outputDevice.GetObjectID() == kAudioObjectUnknown) {
            LogError("BGMAudioDeviceManager::initWithError: output device not found");
            
            if (error) {
                *error = [NSError errorWithDomain:@kBGMAppBundleID code:kBGMErrorCode_OutputDeviceNotFound userInfo:nil];
            }
            
            self = nil;
            return self;
        }
    }
    
    return self;
}

// Throws a CAException if it fails to set the output device.
- (void) initOutputDevice {
    CAHALAudioSystemObject audioSystem;
    // outputDevice = BGMAudioDevice(CFSTR("AppleHDAEngineOutput:1B,0,1,1:0"));
    BGMAudioDevice defaultDevice = audioSystem.GetDefaultAudioDevice(false, false);

    if (defaultDevice.IsBGMDeviceInstance()) {
        // BGMDevice is already the default (it could have been set manually or BGMApp could have
        // failed to change it back the last time it closed), so just pick the device with the
        // lowest latency.
        //
        // TODO: Temporarily disable BGMDevice so we can find out what the previous default was and
        //       use that instead.
        [self setOutputDeviceByLatency];
    } else {
        // TODO: Return the error from setOutputDeviceWithID so it can be returned by initWithError.
        [self setOutputDeviceWithID:defaultDevice revertOnFailure:NO];
    }

    if (outputDevice == kAudioObjectUnknown) {
        LogError("BGMAudioDeviceManager::initOutputDevice: Failed to set output device");
        Throw(CAException(kAudioHardwareUnspecifiedError));
    }

    if (outputDevice.IsBGMDeviceInstance()) {
        LogError("BGMAudioDeviceManager::initOutputDevice: Failed to change output device from "
                 "BGMDevice");
        Throw(CAException(kAudioHardwareUnspecifiedError));
    }
    
    // Log message
    CFStringRef outputDeviceUID = outputDevice.CopyDeviceUID();
    DebugMsg("BGMAudioDeviceManager::initOutputDevice: Set output device to %s",
             CFStringGetCStringPtr(outputDeviceUID, kCFStringEncodingUTF8));
    CFRelease(outputDeviceUID);
}

- (void) setOutputDeviceByLatency {
    CAHALAudioSystemObject audioSystem;
    UInt32 numDevices = audioSystem.GetNumberAudioDevices();

    if (numDevices > 0) {
        BGMAudioDevice minLatencyDevice = kAudioObjectUnknown;
        UInt32 minLatency = UINT32_MAX;

        CAAutoArrayDelete<AudioObjectID> devices(numDevices);
        audioSystem.GetAudioDevices(numDevices, devices);

        for (UInt32 i = 0; i < numDevices; i++) {
            BGMAudioDevice device(devices[i]);

            if (!device.IsBGMDeviceInstance()) {
                BOOL hasOutputChannels = NO;

                BGMLogAndSwallowExceptionsMsg("BGMAudioDeviceManager::setOutputDeviceByLatency",
                                              "GetTotalNumberChannels", ([&] {
                    hasOutputChannels = device.GetTotalNumberChannels(/* inIsInput = */ false) > 0;
                }));

                if (hasOutputChannels) {
                    BGMLogAndSwallowExceptionsMsg("BGMAudioDeviceManager::setOutputDeviceByLatency",
                                                  "GetLatency", ([&] {
                        UInt32 latency = device.GetLatency(false);

                        if (latency < minLatency) {
                            minLatencyDevice = devices[i];
                            minLatency = latency;
                        }
                    }));
                }
            }
        }

        if (minLatencyDevice != kAudioObjectUnknown) {
            // TODO: On error, try a different output device.
            [self setOutputDeviceWithID:minLatencyDevice revertOnFailure:NO];
        }
    }
}

- (void) setOutputVolumeMenuItem:(BGMOutputVolumeMenuItem*)item {
    outputVolumeMenuItem = item;
}

#pragma mark Systemwide Default Device

// Note that there are two different "default" output devices on OS X: "output" and "system output". See
// kAudioHardwarePropertyDefaultSystemOutputDevice in AudioHardware.h.

- (NSError* __nullable) setBGMDeviceAsOSDefault {
    // Copy bgmDevice so we can call the HAL without holding stateLock. See startPlayThroughSync.
    BGMBackgroundMusicDevice bgmDev;

    @try {
        [stateLock lock];
        bgmDev = bgmDevice;
    } @finally {
        [stateLock unlock];
    }

    try {
        bgmDev.SetAsOSDefault();
    } catch (const CAException& e) {
        NSLog(@"SetAsOSDefault threw CAException (%d)", e.GetError());
        return [NSError errorWithDomain:@kBGMAppBundleID code:e.GetError() userInfo:nil];
    }

    return nil;
}

- (NSError* __nullable) unsetBGMDeviceAsOSDefault {
    // Copy the devices so we can call the HAL without holding stateLock. See startPlayThroughSync.
    try {
        BGMBackgroundMusicDevice bgmDev;
        AudioDeviceID outputDeviceID;
        
        @try {
            [stateLock lock];
            bgmDev = bgmDevice;
            outputDeviceID = outputDevice.GetObjectID();
        } @finally {
            [stateLock unlock];
        }

        if (outputDeviceID == kAudioObjectUnknown) {
            return [NSError errorWithDomain:@kBGMAppBundleID
                                       code:kBGMErrorCode_OutputDeviceNotFound
                                   userInfo:nil];
        }

        bgmDev.UnsetAsOSDefault(outputDeviceID);
    } catch (const CAException& e) {
        BGMLogExceptionIn("BGMAudioDeviceManager::unsetBGMDeviceAsOSDefault", e);
        return [NSError errorWithDomain:@kBGMAppBundleID code:e.GetError() userInfo:nil];
    }
    
    return nil;
}

#pragma mark Accessors

- (BGMBackgroundMusicDevice) bgmDevice {
    return bgmDevice;
}

- (CAHALAudioDevice) outputDevice {
    return outputDevice;
}

- (void)  setVolume:(SInt32)volume
forAppWithProcessID:(pid_t)processID
           bundleID:(NSString* __nullable)bundleID {
    bgmDevice.SetAppVolume(volume, processID, (__bridge_retained CFStringRef)bundleID);
}

- (void) setPanPosition:(SInt32)pan
    forAppWithProcessID:(pid_t)processID
               bundleID:(NSString* __nullable)bundleID {
    bgmDevice.SetAppPanPosition(pan, processID, (__bridge_retained CFStringRef)bundleID);
}

- (BOOL) isOutputDevice:(AudioObjectID)deviceID {
    @try {
        [stateLock lock];
        return deviceID == outputDevice.GetObjectID();
    } @finally {
        [stateLock unlock];
    }
}

- (BOOL) isOutputDataSource:(UInt32)dataSourceID {
    BOOL isOutputDataSource = NO;

    @try {
        [stateLock lock];
        
        try {
            AudioObjectPropertyScope scope = kAudioDevicePropertyScopeOutput;
            UInt32 channel = 0;
            
            isOutputDataSource =
                    outputDevice.HasDataSourceControl(scope, channel) &&
                            (dataSourceID == outputDevice.GetCurrentDataSourceID(scope, channel));
        } catch (const CAException& e) {
            BGMLogException(e);
        }
    } @finally {
        [stateLock unlock];
    }

    return isOutputDataSource;
}

#pragma mark Output Device

- (NSError* __nullable) setOutputDeviceWithID:(AudioObjectID)deviceID
                              revertOnFailure:(BOOL)revertOnFailure {
    return [self setOutputDeviceWithIDImpl:deviceID
                              dataSourceID:nil
                           revertOnFailure:revertOnFailure];
}

- (NSError* __nullable) setOutputDeviceWithID:(AudioObjectID)deviceID
                                 dataSourceID:(UInt32)dataSourceID
                              revertOnFailure:(BOOL)revertOnFailure {
    return [self setOutputDeviceWithIDImpl:deviceID
                              dataSourceID:&dataSourceID
                           revertOnFailure:revertOnFailure];
}

- (NSError* __nullable) setOutputDeviceWithIDImpl:(AudioObjectID)newDeviceID
                                     dataSourceID:(UInt32* __nullable)dataSourceID
                                  revertOnFailure:(BOOL)revertOnFailure {
    DebugMsg("BGMAudioDeviceManager::setOutputDeviceWithIDImpl: Setting output device. newDeviceID=%u",
             newDeviceID);
    
    AudioDeviceID currentDeviceID = outputDevice.GetObjectID();  // (GetObjectID doesn't throw.)

    @try {
        [stateLock lock];
        
        try {
            // Re-read the device ID after entering the monitor. (The initial read is because
            // currentDeviceID is used in the catch blocks.)
            currentDeviceID = outputDevice.GetObjectID();
            
            if (newDeviceID != currentDeviceID) {
                BGMAudioDevice newOutputDevice(newDeviceID);
                [self setOutputDeviceForPlaythroughAndControlSync:newOutputDevice];
                outputDevice = newOutputDevice;
            }
            
            // Set the output device to use the new data source.
            if (dataSourceID) {
                // TODO: If this fails, ideally we'd still start playthrough and return an error, but not
                //       revert the device. It would probably be a bit awkward, though.
                [self setDataSource:*dataSourceID device:outputDevice];
            }
            
            if (newDeviceID != currentDeviceID) {
                // We successfully changed to the new device. Start playthrough on it, since audio might be
                // playing. (If we only changed the data source, playthrough will already be running if it
                // needs to be.)
                playThrough.Start();
                playThrough_UISounds.Start();
                // But stop playthrough if audio isn't playing, since it uses CPU.
                playThrough.StopIfIdle();
                playThrough_UISounds.StopIfIdle();
            }
        } catch (CAException e) {
            BGMAssert(e.GetError() != kAudioHardwareNoError,
                      "CAException with kAudioHardwareNoError");
            
            return [self failedToSetOutputDevice:newDeviceID
                                       errorCode:e.GetError()
                                        revertTo:(revertOnFailure ? &currentDeviceID : nullptr)];
        } catch (...) {
            return [self failedToSetOutputDevice:newDeviceID
                                       errorCode:kAudioHardwareUnspecifiedError
                                        revertTo:(revertOnFailure ? &currentDeviceID : nullptr)];
        }

        [self propagateOutputDeviceChange];
    } @finally {
        [stateLock unlock];
    }

    return nil;
}

// Changes the output device that playthrough plays audio to and that BGMDevice's controls are
// kept in sync with. Throws CAException.
- (void) setOutputDeviceForPlaythroughAndControlSync:(const BGMAudioDevice&)newOutputDevice {
    // Deactivate playthrough rather than stopping it so it can't be started by HAL notifications
    // while we're updating deviceControlSync.
    playThrough.Deactivate();
    playThrough_UISounds.Deactivate();

    deviceControlSync.SetDevices(bgmDevice, newOutputDevice);
    deviceControlSync.Activate();

    // Stream audio from BGMDevice to the new output device. This blocks while the old device stops
    // IO.
    playThrough.SetDevices(&bgmDevice, &newOutputDevice);
    playThrough.Activate();

    // TODO: Support setting different devices as the default output device and the default system
    //       output device the way OS X does?
    BGMAudioDevice uiSoundsDevice = bgmDevice.GetUISoundsBGMDeviceInstance();
    playThrough_UISounds.SetDevices(&uiSoundsDevice, &newOutputDevice);
    playThrough_UISounds.Activate();
}

- (void) setDataSource:(UInt32)dataSourceID device:(BGMAudioDevice&)device {
    BGMLogAndSwallowExceptions("BGMAudioDeviceManager::setDataSource", [&] {
        AudioObjectPropertyScope scope = kAudioObjectPropertyScopeOutput;
        UInt32 channel = 0;

        if (device.DataSourceControlIsSettable(scope, channel)) {
            DebugMsg("BGMAudioDeviceManager::setOutputDeviceWithID: Setting dataSourceID=%u",
                     dataSourceID);
            
            device.SetCurrentDataSourceByID(scope, channel, dataSourceID);
        }
    });
}

- (void) propagateOutputDeviceChange {
    // Tell BGMXPCHelper that the output device has changed.
    [self sendOutputDeviceToBGMXPCHelper];

    // Update the menu item for the volume of the output device.
    [outputVolumeMenuItem outputDeviceDidChange];
}

- (NSError*) failedToSetOutputDevice:(AudioDeviceID)deviceID
                           errorCode:(OSStatus)errorCode
                            revertTo:(AudioDeviceID*)revertTo {
    // Using LogWarning from PublicUtility instead of NSLog here crashes from a bad access. Not sure why.
    NSLog(@"BGMAudioDeviceManager::failedToSetOutputDevice: Couldn't set device with ID %u as output device. "
          "%s%d. %@",
          deviceID,
          "Error: ", errorCode,
          (revertTo ? [NSString stringWithFormat:@"Will attempt to revert to the previous device. "
                                                  "Previous device ID: %u.", *revertTo] : @""));
    
    NSDictionary* __nullable info = nil;
    
    if (revertTo) {
        // Try to reactivate the original device listener and playthrough. (Sorry about the mutual recursion.)
        NSError* __nullable revertError = [self setOutputDeviceWithID:*revertTo revertOnFailure:NO];
        
        if (revertError) {
            info = @{ @"revertError": (NSError*)revertError };
        }
    } else {
        // TODO: Handle this error better in callers. Maybe show an error dialog and try to set the original
        //       default device as the output device.
        NSLog(@"BGMAudioDeviceManager::failedToSetOutputDevice: Failed to revert to the previous device.");
    }
    
    return [NSError errorWithDomain:@kBGMAppBundleID code:errorCode userInfo:info];
}

- (OSStatus) startPlayThroughSync:(BOOL)forUISoundsDevice {
    // We can only try for stateLock because setOutputDeviceWithID might have already taken it, then made a
    // HAL request to BGMDevice and be waiting for the response. Some of the requests setOutputDeviceWithID
    // makes to BGMDevice block in the HAL if another thread is in BGM_Device::StartIO.
    //
    // Since BGM_Device::StartIO calls this method (via XPC), waiting for setOutputDeviceWithID to release
    // stateLock could cause deadlocks. Instead we return early with an error code that BGMDriver knows to
    // ignore, since the output device is (almost certainly) being changed and we can't avoid dropping frames
    // while the output device starts up.
    OSStatus err;
    BOOL gotLock;
    
    @try {
        gotLock = [stateLock tryLock];
        
        if (gotLock) {
            BGMPlayThrough& pt = (forUISoundsDevice ? playThrough_UISounds : playThrough);

            // Playthrough might not have been notified that BGMDevice is starting yet, so make sure
            // playthrough is starting. This way we won't drop any frames while waiting for the HAL to send
            // that notification. We can't be completely sure this is safe from deadlocking, though, since
            // CoreAudio is closed-source.
            //
            // TODO: Test this on older OS X versions. Differences in the CoreAudio implementations could
            //       cause deadlocks.
            BGMLogAndSwallowExceptionsMsg("BGMAudioDeviceManager::startPlayThroughSync",
                                          "Starting playthrough", [&] {
                pt.Start();
            });

            err = pt.WaitForOutputDeviceToStart();
            BGMAssert(err != BGMPlayThrough::kDeviceNotStarting, "Playthrough didn't start");
        } else {
            LogWarning("BGMAudioDeviceManager::startPlayThroughSync: Didn't get state lock. Returning "
                       "early with kBGMErrorCode_ReturningEarly.");
            err = kBGMErrorCode_ReturningEarly;

            dispatch_async(BGMGetDispatchQueue_PriorityUserInteractive(), ^{
                @try {
                    [stateLock lock];

                    BGMPlayThrough& pt = (forUISoundsDevice ? playThrough_UISounds : playThrough);
                    
                    BGMLogAndSwallowExceptionsMsg("BGMAudioDeviceManager::startPlayThroughSync",
                                                  "Starting playthrough (dispatched)", [&] {
                        pt.Start();
                    });

                    BGMLogAndSwallowExceptions("BGMAudioDeviceManager::startPlayThroughSync", [&] {
                        pt.StopIfIdle();
                    });
                } @finally {
                    [stateLock unlock];
                }
            });
        }
    } @finally {
        if (gotLock) {
            [stateLock unlock];
        }
    }
    
    return err;
}

#pragma mark BGMXPCHelper Communication

- (void) setBGMXPCHelperConnection:(NSXPCConnection* __nullable)connection {
    bgmXPCHelperConnection = connection;

    // Tell BGMXPCHelper which device is the output device, since it might not be up-to-date.
    [self sendOutputDeviceToBGMXPCHelper];
}

- (void) sendOutputDeviceToBGMXPCHelper {
    NSXPCConnection* __nullable connection = bgmXPCHelperConnection;

    if (connection)
    {
        id<BGMXPCHelperXPCProtocol> helperProxy =
                [connection remoteObjectProxyWithErrorHandler:^(NSError* error) {
                    // We could wait a bit and try again, but it isn't that important.
                    NSLog(@"BGMAudioDeviceManager::sendOutputDeviceToBGMXPCHelper: Connection"
                           "error: %@", error);
                }];

        [helperProxy setOutputDeviceToMakeDefaultOnAbnormalTermination:outputDevice.GetObjectID()];
    }
}

@end

#pragma clang assume_nonnull end


