#import "Pitchy.h"
#import <AVFoundation/AVFoundation.h>
#import <React/RCTLog.h>

@implementation Pitchy {
    AVAudioEngine *audioEngine;
    double sampleRate;
    double minVolume;
    BOOL isRecording;
    BOOL isInitialized;
    
    // Store original audio session configuration
    NSString *originalCategory;
    NSString *originalMode;
    AVAudioSessionCategoryOptions originalOptions;
    double originalSampleRate;
    double originalIOBufferDuration;
    
    // Store configuration for reinitialization
    NSDictionary *config;
}

RCT_EXPORT_MODULE()

- (NSArray<NSString *> *)supportedEvents {
  return @[@"onPitchDetected"];
}

RCT_EXPORT_METHOD(init:(NSDictionary *)initConfig) {
    #if TARGET_IPHONE_SIMULATOR
        RCTLogInfo(@"Pitchy module is not supported on the iOS simulator");
        return;
    #endif
    
    // Store config for reinitialization
    config = initConfig;
    
    if (!isInitialized) {
        [self setupAudioSession];
        [self setupAudioEngine];
        isInitialized = YES;
    }
}

- (void)setupAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    
    // Store original audio session configuration only once
    if (!originalCategory) {
        originalCategory = session.category;
        originalMode = session.mode;
        originalOptions = session.categoryOptions;
        originalSampleRate = session.sampleRate;
        originalIOBufferDuration = session.IOBufferDuration;
        
        RCTLogInfo(@"Stored original audio session - Category: %@, Mode: %@, SampleRate: %f", 
                   originalCategory, originalMode, originalSampleRate);
    }

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
}

- (void)setupAudioEngine {
    // Clean up existing audio engine if it exists
    if (audioEngine) {
        if (audioEngine.isRunning) {
            [audioEngine stop];
        }
        [audioEngine reset];
    }
    
    // Initialize new audio engine
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
    
    // Remove any existing tap
    [inputNode removeTapOnBus:0];
    
    // Install tap with the configured format
    [inputNode installTapOnBus:0 
                   bufferSize:[config[@"bufferSize"] unsignedIntValue] 
                       format:format 
                        block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
        [self detectPitch:buffer];
    }];
    
    RCTLogInfo(@"Audio engine setup complete - SampleRate: %f, BufferSize: %u", 
               sampleRate, [config[@"bufferSize"] unsignedIntValue]);
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

    // Reinitialize audio engine for each start to ensure clean state
    [self setupAudioSession];
    [self setupAudioEngine];

    NSError *error = nil;
    [audioEngine startAndReturnError:&error];
    if (error) {
        RCTLogError(@"Failed to start audio engine: %@", error);
        reject(@"start_error", @"Failed to start audio engine", error);
    } else {
        isRecording = YES;
        RCTLogInfo(@"Audio engine started successfully");
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
    
    // Reset the audio engine for next use
    [audioEngine reset];
    
    // Restore original audio session configuration
    [self restoreAudioSession];
    
    RCTLogInfo(@"Audio engine stopped and reset");
    resolve(@(YES));
}

- (void)restoreAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    
    RCTLogInfo(@"Restoring audio session to playback-friendly state");
    
    // Force the audio session to a playback-friendly configuration
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:&error];
    if (error) {
        RCTLogError(@"Error setting AVAudioSession to playback category: %@", error);
    }
    
    // Set a reasonable sample rate for playback
    [session setPreferredSampleRate:44100 error:&error];
    if (error) {
        RCTLogError(@"Error setting sample rate: %@", error);
    }
    
    // Set a reasonable buffer duration for playback
    [session setPreferredIOBufferDuration:0.023 error:&error];
    if (error) {
        RCTLogError(@"Error setting I/O buffer duration: %@", error);
    }
    
    // Reactivate the session with playback settings
    [session setActive:YES error:&error];
    if (error) {
        RCTLogError(@"Error reactivating AVAudioSession: %@", error);
    }
    
    RCTLogInfo(@"Audio session restored to playback mode");
}

- (void)detectPitch:(AVAudioPCMBuffer *)buffer {
    float *channelData = buffer.floatChannelData[0];
    std::vector<double> buf(channelData, channelData + buffer.frameLength);

    double detectedPitch = pitchy::autoCorrelate(buf, sampleRate, minVolume);
    
    [self sendEventWithName:@"onPitchDetected" body:@{@"pitch": @(detectedPitch)}];
}

@end
