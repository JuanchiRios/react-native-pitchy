#import "Pitchy.h"
#import <AVFoundation/AVFoundation.h>
#import <React/RCTLog.h>

@implementation Pitchy {
    AVAudioEngine *audioEngine;
    double sampleRate;
    double minVolume;
    BOOL isRecording;
    BOOL isInitialized;
}

RCT_EXPORT_MODULE()

- (NSArray<NSString *> *)supportedEvents {
  return @[@"onPitchDetected"];
}

RCT_EXPORT_METHOD(init:(NSDictionary *)config) {
    #if TARGET_IPHONE_SIMULATOR
        RCTLogInfo(@"Pitchy module is not supported on the iOS simulator");
        return;
    #endif
    if (!isInitialized) {
        // Configure audio session first
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *error = nil;
        

        // Set preferred sample rate and I/O buffer duration
        [session setPreferredSampleRate:44100 error:&error];
        if (error) {
            RCTLogError(@"Error setting preferred sample rate: %@", error);
        }
        
        [session setPreferredIOBufferDuration:0.005 error:&error];
        if (error) {
            RCTLogError(@"Error setting preferred I/O buffer duration: %@", error);
        }
        
        // Configure audio session category and mode
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                        mode:AVAudioSessionModeMeasurement
                     options:AVAudioSessionCategoryOptionDefaultToSpeaker
                       error:&error];
        if (error) {
            RCTLogError(@"Error setting AVAudioSession category: %@", error);
        }
        
        // Activate the session
        [session setActive:YES error:&error];
        if (error) {
            RCTLogError(@"Error activating AVAudioSession: %@", error);
        }

        // Initialize audio engine after session configuration
        audioEngine = [[AVAudioEngine alloc] init];
        AVAudioInputNode *inputNode = [audioEngine inputNode];
        
        // Get the actual format after session configuration
        AVAudioFormat *format = [inputNode inputFormatForBus:0];
        if (format.sampleRate == 0) {
            RCTLogError(@"Invalid sample rate: %f", format.sampleRate);
            return;
        }
        
        sampleRate = format.sampleRate;
        minVolume = [config[@"minVolume"] doubleValue];
        
        // Install tap with the configured format
        [inputNode installTapOnBus:0 
                       bufferSize:[config[@"bufferSize"] unsignedIntValue] 
                           format:format 
                            block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
            [self detectPitch:buffer];
        }];

        isInitialized = YES;
    }
}

RCT_EXPORT_METHOD(isRecording:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    resolve([NSNumber numberWithBool:isRecording]);
}

RCT_EXPORT_METHOD(start:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    if (!isInitialized) {
        reject(@"not_initialized", @"Pitchy module is not initialized", nil);
        return;
    }

    if(isRecording){
        reject(@"already_recording", @"Already recording", nil);
        return;
    }

    NSError *error = nil;
    [audioEngine startAndReturnError:&error];
    if (error) {
        reject(@"start_error", @"Failed to start audio engine", error);
    } else {
        isRecording = YES;
        resolve(@(YES));
    }
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
                    
    if (!isRecording) {
        reject(@"not_recording", @"Not recording", nil);
        return;
    }

    [audioEngine stop];
    isRecording = NO;
    resolve(@(YES));
}

- (void)detectPitch:(AVAudioPCMBuffer *)buffer {
    float *channelData = buffer.floatChannelData[0];
    std::vector<double> buf(channelData, channelData + buffer.frameLength);

    double detectedPitch = pitchy::autoCorrelate(buf, sampleRate, minVolume);
    
    [self sendEventWithName:@"onPitchDetected" body:@{@"pitch": @(detectedPitch)}];
}

@end
