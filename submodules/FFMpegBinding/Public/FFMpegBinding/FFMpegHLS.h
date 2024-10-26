#import <Foundation/Foundation.h>
#import <CoreVideo/CVPixelBuffer.h>
#import <CoreMedia/CMSampleBuffer.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFMpegHLS : NSObject

- (int) open:(NSString*)url;

- (Boolean) hasMoreVideoFrames;

- (CMSampleBufferRef _Nullable) getNextVideoFrame;

- (Boolean) hasMoreAudioFrames;

- (CMSampleBufferRef _Nullable) getNextAudioFrame;

- (void) seek:(CMTime)to;

- (void) setupAvailableQualities:(NSArray<NSNumber *> *)qualities;

@property NSInteger quality;

@end

NS_ASSUME_NONNULL_END
