#import <FFMpegBinding/FFMpegHLS.h>

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>

#import "libavcodec/avcodec.h"
#import "libavformat/avformat.h"
#import "libavformat/avio.h"
#import "libavutil/avutil.h"
#import "libavutil/opt.h"
#include "libswresample/swresample.h"

#define BUFFER_SIZE_SECONDS 3
#define AVIO_BUFFER_SIZE 4096

enum AVPixelFormat get_hw_format(AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts) {
    for (const enum AVPixelFormat *p = pix_fmts; *p != -1; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *p;
        }
    }
    fprintf(stderr, "Cannot find VideoToolbox pixel format\n");
    return AV_PIX_FMT_NONE;
}

@interface Variant : NSObject

@property NSInteger bandwidth;
@property NSInteger width;
@property NSInteger height;
@property NSURL *url;

- (instancetype)initWithAttributes:(NSString *)input;
@end

@implementation Variant
- (instancetype)initWithAttributes:(NSString *)input {
    self = [super init];
    if (self) {
        // "BANDWIDTH=2074088,RESOLUTION=1920x1080"
        NSArray *items = [input componentsSeparatedByString:@","];

        for (NSString *item in items) {
            NSArray *parts = [item componentsSeparatedByString:@"="];
            if (parts.count == 2) {
                NSString *key = parts[0];
                NSString *val = parts[1];
                if ([key isEqualToString: @"BANDWIDTH"]) {
                    self.bandwidth = [val integerValue];
                }
                else if ([key isEqualToString: @"RESOLUTION"]) {
                    NSArray *resolutionParts = [val componentsSeparatedByString:@"x"];
                    if (resolutionParts.count == 2) {
                        NSString *w = resolutionParts[0];
                        NSString *h = resolutionParts[1];
                        self.width = [w integerValue];
                        self.height = [h integerValue];
                    }
                }
            }
        };
    }
    return self;
}

- (char *)getStringURL {
    return strdup([[self.url absoluteString] UTF8String]);
}
@end

@interface Playlist : NSObject

@property NSURL *url;
@property (nonatomic, strong) NSMutableArray<Variant *> *variants;

- (instancetype)initWithString:(NSString *)input;
+ (instancetype)fromUrl:(NSURL *)url;

@end

@implementation Playlist
- (instancetype)init {
    self = [super init];
    if (self) {
        self.variants = [NSMutableArray array]; // Инициализация пустого массива
    }
    return self;
}

- (instancetype)initWithString:(NSString *)input {
    self = [self init];
    if (self) {
        __block bool isVariant = false;
//        __block bool isSegment = false;
        __block Variant *variant;
        
        [input enumerateLinesUsingBlock:^(NSString *item, bool *stop){
            NSArray *parts = [item componentsSeparatedByString:@":"];
            if (parts.count == 2) {
                NSString *key = parts[0];
                NSString *val = parts[1];
                if ([key isEqualToString: @"#EXT-X-STREAM-INF"]) {
                    isVariant = true;
                    variant = [[Variant alloc] initWithAttributes:val];
                }
            } else if (parts.count == 1) {
                NSString *val = parts[0];
                if (isVariant) {
                    NSURL *newURL = [[self.url URLByDeletingLastPathComponent] URLByAppendingPathComponent:val];
                    variant.url = newURL;
                    [self.variants addObject:variant];
                    isVariant = false;
                }
            }
        }];
    }
    return self;
}

+ (instancetype)fromUrl:(NSURL *)url {
    __block Playlist *playlist = [Playlist alloc];
    playlist.url = url;
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"Error: %@", error);
        } else {
            NSString *responseString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            playlist = [playlist initWithString:responseString];
        }
        
        dispatch_semaphore_signal(sem);
    }];
    
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    
    return playlist;
}

@end

@interface SpeedMeasurer : NSObject

@property (nonatomic, strong) Playlist *playlist;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *measurements;
@property (nonatomic, assign) NSInteger maxMeasurements;
@property (nonatomic, strong) Variant *currentVariant;

@property (nonatomic, copy) void (^qualityChangeHandler)(Variant *newVariant);

- (instancetype)initWithPlaylist:(Playlist *)playlist;
- (void)addMeasurement:(int)bps;

@end

@implementation SpeedMeasurer

- (instancetype)initWithPlaylist:(Playlist *)playlist {
    self = [super init];
    if (self) {
        _playlist = playlist;
        _measurements = [NSMutableArray array];
        _maxMeasurements = 5;
        _currentVariant = playlist.variants.firstObject;
    }
    return self;
}

- (void)addMeasurement:(int)bps {
    [self.measurements addObject:@(bps)];
    if (self.measurements.count > self.maxMeasurements) {
        [self.measurements removeObjectAtIndex:0];
    }
    
    Variant *recommendedVariant = [self selectVariantForCurrentSpeed];
    if (recommendedVariant != self.currentVariant) {
        self.currentVariant = recommendedVariant;
        if (self.qualityChangeHandler) {
            self.qualityChangeHandler(recommendedVariant);
        }
    }
}

- (double)averageSpeed {
    double sum = 0;
    for (NSNumber *measurement in self.measurements) {
        sum += measurement.doubleValue;
    }
    return (self.measurements.count > 0) ? sum / self.measurements.count : 0;
}

- (Variant *)selectVariantForCurrentSpeed {
    double avgSpeed = [self averageSpeed];
    
    NSArray *sortedVariants = [self.playlist.variants sortedArrayUsingComparator:^NSComparisonResult(Variant *v1, Variant *v2) {
        return [@(v1.bandwidth) compare:@(v2.bandwidth)];
    }];
    
    Variant *selectedVariant = sortedVariants.firstObject;
    for (Variant *variant in sortedVariants) {
        if (avgSpeed >= variant.bandwidth) {
            selectedVariant = variant;
        } else {
            break;
        }
    }
    
//    printf("AUTO SELECTED VARIANT: %d, SPEED: %d", (int)selectedVariant.bandwidth, (int)avgSpeed);
    return selectedVariant;
}

@end

struct IOCustomCtx {
    NSData *data;
    NSUInteger offset;
};

int ioCustomRead(void *opaque, uint8_t *buf, int buf_size) {
    struct IOCustomCtx *ctx = (struct IOCustomCtx *)opaque;

    // Check if we've reached the end of the data
    NSUInteger dataLength = [ctx->data length];
    if (ctx->offset >= dataLength) {
        return AVERROR_EOF;
    }

    int copySize = (int)MIN(buf_size, dataLength - ctx->offset);

    [ctx->data getBytes:buf range:NSMakeRange(ctx->offset, copySize)];
    ctx->offset += copySize;

    return copySize;
}

int ioCustomOpen(struct AVFormatContext *s, AVIOContext **pb, const char *url,
                 int flags, AVDictionary **options) {
    SpeedMeasurer *speedMeasurer = (__bridge SpeedMeasurer *)s->opaque;
    
    NSURL *reqUrl = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:reqUrl];
    
    // Extract `offset` and `end_offset` values from `options`
    AVDictionaryEntry *offsetEntry = av_dict_get(*options, "offset", NULL, 0);
    AVDictionaryEntry *endOffsetEntry = av_dict_get(*options, "end_offset", NULL, 0);
    
    if (offsetEntry && endOffsetEntry) {
        int offset = atoi(offsetEntry->value);
        int endOffset = atoi(endOffsetEntry->value);
        
        // Create the byte range header value
        NSString *rangeValue = [NSString stringWithFormat:@"bytes=%d-%d", offset, endOffset];
        
        // Set the byte range header
        [request setValue:rangeValue forHTTPHeaderField:@"Range"];
    }
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sharedSession];
    
    __block NSData *data = nil;
    
    NSLog(@"Request: %s", url);
    
    // Start the timer
    NSDate *startTime = [NSDate date];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *resData, NSURLResponse *response, NSError *error) {
        data = resData;
        if (error) {
            NSLog(@"Error: %@", error);
        }
        
        dispatch_semaphore_signal(sem);
    }];

    [task resume];
    
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    
    // Stop the timer and calculate elapsed time in seconds
    NSTimeInterval elapsedTime = [[NSDate date] timeIntervalSinceDate:startTime];

    // Calculate download speed in bits per second
    NSUInteger dataSizeInBits = [data length] * 8;
    double speedBps = dataSizeInBits / elapsedTime;
    [speedMeasurer addMeasurement: speedBps];
    NSLog(@"Download speed: %.2f bits per second", speedBps);
    
    struct IOCustomCtx *ctx = malloc(sizeof(struct IOCustomCtx));
    ctx->data = data;
    ctx->offset = 0;
    
    uint8_t *avio_buffer = av_malloc(AVIO_BUFFER_SIZE);
    AVIOContext *avio_ctx = avio_alloc_context(avio_buffer, AVIO_BUFFER_SIZE, 0, ctx, ioCustomRead, NULL, NULL);
    
    avio_ctx->opaque = ctx;
    *pb = avio_ctx;
    
    return 0;
}

void ioCustomClose(struct AVFormatContext *s, AVIOContext *pb) {
    av_free(pb->buffer);
    avio_context_free(&pb);
}

@interface FFMpegHLS () {
    NSMutableArray *_readyVideoFramesBuffer;
    NSMutableArray *_readyAudioFramesBuffer;
    
    dispatch_queue_t _decodingQueue;
    
    int _videoStreamIndex;
    int _audioStreamIndex;
    
    bool _hasMoreVideoFrames;
    bool _hasMoreAudioFrames;
    
    AVFormatContext *_fmtCtx;
    SwrContext *_swrCtx;
    
    AVCodecContext *_videoCodecCtx;
    AVCodecContext *_audioCodecCtx;
}

@property bool isPlaybackBufferEmpty;
@property bool isPlaybackBufferFull;

@property bool isStopDecodingRequested;

@property int64_t lastKeyframe;

@property NSArray<NSNumber *> *qualities;

@property bool eof;
@property bool isBuffering;

@property Playlist *master;
@property SpeedMeasurer *speedMeasurer;

@end

@implementation FFMpegHLS

@synthesize quality = _quality;
@synthesize currectQuality = _currectQuality;

- (instancetype) init {
    self = [super init];
    if (self) {
        _readyVideoFramesBuffer = [[NSMutableArray alloc] init];
        _readyAudioFramesBuffer = [[NSMutableArray alloc] init];
        
        _decodingQueue = dispatch_queue_create("hls.decoding", DISPATCH_QUEUE_SERIAL);
        
        self.isStopDecodingRequested = false;
    }
    return self;
}

- (int) open: (NSString*) url {
    _hasMoreVideoFrames = true;
    _hasMoreAudioFrames = true;
    
    // notify player
    self.isPlaybackBufferEmpty = true;
    
    [self printVersions];
    
    av_log_set_level(AV_LOG_INFO);
    
    self.master = [Playlist fromUrl:[NSURL URLWithString:url]];
    self.speedMeasurer = [[SpeedMeasurer alloc] initWithPlaylist:self.master];
    
    const char* urlStr = [url UTF8String];
    
    _fmtCtx = avformat_alloc_context();
    _fmtCtx->io_open = ioCustomOpen;
    _fmtCtx->io_close = ioCustomClose;
    _fmtCtx->flags |= AVFMT_FLAG_CUSTOM_IO;
    _fmtCtx->opaque = (__bridge void *)(self.speedMeasurer);
    
    int err = avformat_open_input(&_fmtCtx, urlStr, NULL, NULL);
    if (err < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not open input file: %s\n%s\n", urlStr, av_err2str(err));
        return -1;
    }
    
    _videoStreamIndex = 0;
    _audioStreamIndex = 1;
    _currectQuality = [self.master.variants objectAtIndex:0].height;
    
    err = avformat_find_stream_info(_fmtCtx, NULL);
    if (err < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not find stream information.\n%s\n", av_err2str(err));
        avformat_close_input(&_fmtCtx);
        return -1;
    }
    
    [self selectStreams];
    
    [self initCodecs];
    
    if (_audioCodecCtx) {
        _swrCtx = swr_alloc();
        
        av_opt_set_int(_swrCtx, "in_channel_layout",  _audioCodecCtx->channel_layout, 0);
        av_opt_set_int(_swrCtx, "out_channel_layout",  _audioCodecCtx->channel_layout, 0);
        av_opt_set_int(_swrCtx, "in_sample_rate", _audioCodecCtx->sample_rate, 0);
        av_opt_set_int(_swrCtx, "out_sample_rate", _audioCodecCtx->sample_rate, 0);
        av_opt_set_sample_fmt(_swrCtx, "in_sample_fmt",  AV_SAMPLE_FMT_FLTP, 0);
        av_opt_set_sample_fmt(_swrCtx, "out_sample_fmt", AV_SAMPLE_FMT_S16,  0);
    
        swr_init(_swrCtx);
    }
    
    __weak typeof(self) weakSelf = self;
    self.speedMeasurer.qualityChangeHandler = ^(Variant *newVariant) {
        if (weakSelf.quality == -1) {
            [weakSelf switchToVariant:newVariant];
        }
    };
    
    [self fillBuffer];
    
    return 0;
}

- (void) selectStreams {
    for (int i = 0; i < _fmtCtx->nb_streams; i++) {
        if (i != _videoStreamIndex && i != _audioStreamIndex) {
            _fmtCtx->streams[i]->discard = AVDISCARD_ALL;
        } else {
            _fmtCtx->streams[i]->discard = AVDISCARD_DEFAULT;
        }
    }
}

- (void) setQuality:(NSInteger)quality {
    _quality = quality;
    printf("SET QUALITY %lld\n", (int64_t)quality);
    if (quality != -1) {
        _currectQuality = quality;
        self.isStopDecodingRequested = true;
        dispatch_async(_decodingQueue, ^{
            NSInteger targetProgramIndex = [self.qualities indexOfObject:@(quality)];
            [self switchToProgram:targetProgramIndex];
        });
    }
}

- (void) switchToVariant:(Variant *) variant {
    _currectQuality = variant.height;
    dispatch_async(_decodingQueue, ^{
        NSInteger targetProgramIndex = [self.master.variants indexOfObject:variant];
        [self switchToProgram:targetProgramIndex];
    });
}

- (void) switchToProgram:(NSInteger) targetProgramIndex {
    int newVideoStreamIndex = -1;
    int newAudioStreamIndex = -1;
    
    AVProgram *program = _fmtCtx->programs[targetProgramIndex];
    for (unsigned int j = 0; j < program->nb_stream_indexes; j++) {
        int stream_index = program->stream_index[j];
        AVStream *stream = _fmtCtx->streams[stream_index];
        
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            newVideoStreamIndex = stream_index;
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            newAudioStreamIndex = stream_index;
        }
        
        if (newVideoStreamIndex != -1 && newAudioStreamIndex != -1) {
            break;
        }
    }
    
    _videoStreamIndex = newVideoStreamIndex;
    _audioStreamIndex = newAudioStreamIndex;
    
    [self selectStreams];

    avformat_flush(_fmtCtx);
    
    int err = av_seek_frame(_fmtCtx, _videoStreamIndex, self.lastKeyframe, AVSEEK_FLAG_BACKWARD);
    if (err < 0) {
        av_log(NULL, AV_LOG_ERROR, "Seek frame failed.\n%s\n", av_err2str(err));
        return;
    }
    
    [self deinitCodecs];
    [self initCodecs];
    
    self.isStopDecodingRequested = false;
    [self fillBuffer];
}

- (void) setupAvailableQualities:(NSArray<NSNumber *> *)qualities {
    self.qualities = qualities;
}

- (NSInteger) quality {
    return _quality;
}

- (Boolean) finished {
    return self.eof;
}

- (Boolean) hasMoreVideoFrames {
    return _hasMoreVideoFrames || _readyVideoFramesBuffer.count > 0;
}

- (CMSampleBufferRef) getNextVideoFrame {
    CMSampleBufferRef frame = NULL;
    
    @synchronized (_readyVideoFramesBuffer) {
        if (_readyVideoFramesBuffer.count > 0) {
            NSValue *frameValue = [_readyVideoFramesBuffer firstObject];
            frame = (CMSampleBufferRef)[frameValue pointerValue];
            CFRelease(frame);
            [_readyVideoFramesBuffer removeObjectAtIndex:0];
            if (_readyVideoFramesBuffer.count == 0) {
                self.isPlaybackBufferEmpty = true;
            }
        }
    }
    [self fillBuffer];
    return frame;
}

- (Boolean) hasMoreAudioFrames {
    return _hasMoreAudioFrames || _readyAudioFramesBuffer.count > 0;
}

- (CMSampleBufferRef) getNextAudioFrame {
    CMSampleBufferRef frame = NULL;
    
    @synchronized (_readyAudioFramesBuffer) {
        if (_readyAudioFramesBuffer.count > 0) {
            NSValue *frameValue = [_readyAudioFramesBuffer firstObject];
            frame = (CMSampleBufferRef)[frameValue pointerValue];
            CFRelease(frame);
            [_readyAudioFramesBuffer removeObjectAtIndex:0];
            if (_readyAudioFramesBuffer.count == 0) {
                self.isPlaybackBufferEmpty = true;
            }
        }
    }
    [self fillBuffer];
    return frame;
}

- (void) seek: (CMTime) to {
    self.isStopDecodingRequested = true;
    dispatch_sync(_decodingQueue, ^{
        [self clearBuffer: _readyVideoFramesBuffer];
        [self clearBuffer: _readyAudioFramesBuffer];
        self.isPlaybackBufferEmpty = true;
        self.isPlaybackBufferFull = false;
        
        avcodec_flush_buffers(_videoCodecCtx);
        avcodec_flush_buffers(_audioCodecCtx);
        
        int base = _fmtCtx->streams[_videoStreamIndex]->time_base.den;
        double ts = CMTimeGetSeconds(to) * base;
        int err = av_seek_frame(_fmtCtx, _videoStreamIndex, ts, AVSEEK_FLAG_BACKWARD);
        if (err < 0) {
            av_log(NULL, AV_LOG_ERROR, "Seek frame failed.\n%s\n", av_err2str(err));
            return;
        }
        // refill buffers
        self.isStopDecodingRequested = false;
        self.eof = false;
        [self fillBuffer];
    });
}

- (double) estimatedBufferedDuration: (NSArray*) buffer {
    double duration = 0;
    @synchronized (buffer) {
        for (NSValue *value in buffer) {
            CMSampleBufferRef frame = [value pointerValue];
            duration += CMTimeGetSeconds(CMSampleBufferGetDuration(frame));
        }
    }
    return duration;
}

- (void) printBufferSizes {
    double videoBufferDuration = [self estimatedBufferedDuration: _readyVideoFramesBuffer];
    double audioBufferDuration = [self estimatedBufferedDuration: _readyAudioFramesBuffer];
    printf("===\nVIDEO BUFFER: %.3f s - %d frames\nAUDIO BUFFER: %.3f s - %d frames\n", videoBufferDuration, (int)[_readyVideoFramesBuffer count], audioBufferDuration, (int)[_readyAudioFramesBuffer count]);
}

- (bool) needToDecodeMore {
    bool needMoreVideo = _videoStreamIndex >= 0 && [self estimatedBufferedDuration: _readyVideoFramesBuffer] < 3;
    bool needMoreAudio = _audioStreamIndex >= 0 && [self estimatedBufferedDuration: _readyAudioFramesBuffer] < 3;
    return needMoreVideo || needMoreAudio;
}

- (int)decodeVideo:(AVPacket *)packet {
    int err = avcodec_send_packet(_videoCodecCtx, packet);
    if (err < 0) {
        av_log(NULL, AV_LOG_ERROR, "Send packet failed.\n%s\n", av_err2str(err));
        // well, let's try to skip it
        av_packet_unref(packet);
        return err;
    }
    AVFrame *frame = av_frame_alloc();
    do {
        err = avcodec_receive_frame(_videoCodecCtx, frame);
        if (err == AVERROR_EOF) {
            printf("===\n avcodec_receive_frame AVERROR_EOF\n");
            _hasMoreVideoFrames = false;
            break;
        }
        if (err == AVERROR(EAGAIN)) {
            break;
        }
        if (err < 0) {
            av_log(NULL, AV_LOG_ERROR, "Receive frame failed.\n%s\n", av_err2str(err));
            break;
        }
        
        if ((frame)->key_frame) {
            self.lastKeyframe = (frame)->pts;
        }
        
        AVStream *currectStream = _fmtCtx->streams[_videoStreamIndex];
        CMSampleBufferRef bufferRef = [self createVideoSampleBuffer:frame fromStream:currectStream];
        CFRetain(bufferRef);
        NSValue *bufferValue = [NSValue valueWithPointer:bufferRef];
        @synchronized (_readyVideoFramesBuffer) {
            [_readyVideoFramesBuffer addObject:bufferValue];
            self.isPlaybackBufferEmpty = false;
        }
        
        av_frame_unref(frame);
    } while (err >= 0);
    
    av_frame_free(&frame);
    
    if (err == AVERROR_EOF) {
        return 0;
    }
    return err;
}

- (int) decodeAudio:(AVPacket *)packet {
    int err = avcodec_send_packet(_audioCodecCtx, packet);
    if (err < 0) {
        av_log(NULL, AV_LOG_ERROR, "Send packet failed.\n%s\n", av_err2str(err));
        // well, let's try to skip it
        av_packet_unref(packet);
        return err;
    }
    AVFrame *frame = av_frame_alloc();
    do {
        err = avcodec_receive_frame(_audioCodecCtx, frame);
        if (err == AVERROR_EOF) {
            printf("===\n avcodec_receive_frame AVERROR_EOF\n");
            _hasMoreAudioFrames = false;
            break;
        }
        if (err == AVERROR(EAGAIN)) {
            break;
        }
        if (err < 0) {
            av_log(NULL, AV_LOG_ERROR, "Receive frame failed.\n%s\n", av_err2str(err));
            return err;
        }
        
        AVStream *currectStream = _fmtCtx->streams[_audioStreamIndex];
        CMSampleBufferRef bufferRef = [self createAudioSampleBuffer:frame fromStream:currectStream];
        CFRetain(bufferRef);
        NSValue *bufferValue = [NSValue valueWithPointer:bufferRef];
        @synchronized (_readyAudioFramesBuffer) {
            [_readyAudioFramesBuffer addObject:bufferValue];
            self.isPlaybackBufferEmpty = false;
        }
        
        av_frame_unref(frame);
    } while (err >= 0);
    
    av_frame_free(&frame);
    
    if (err == AVERROR_EOF) {
        return 0;
    }
    return err;
}

- (void) fillBuffer {
    @synchronized (self) {
        if (self.isBuffering || ![self needToDecodeMore]) {
//            printf("===\n SKIP fillBuffer\n");
            return;
        }
        
//        printf("===\n START fillBuffer\n");
//        [self printBufferSizes];
        self.isBuffering = true;
    }
    
    dispatch_async(_decodingQueue, ^{
        AVPacket *packet = av_packet_alloc();
        while (!self.eof && !self.isStopDecodingRequested && [self needToDecodeMore]) {
            int err = av_read_frame(_fmtCtx, packet);
            if (err == AVERROR_EOF) {
                printf("===\n av_read_frame AVERROR_EOF\n");
                self.eof = true;
                [self decodeVideo:NULL];
                [self decodeAudio:NULL];
                break;
            }
            else if (err < 0) {
                av_log(NULL, AV_LOG_ERROR, "Read frame failed.\n%s\n", av_err2str(err));
                return;
            }
            if (packet->stream_index == _videoStreamIndex) {
                [self decodeVideo:packet];
            }
            else if (packet->stream_index == _audioStreamIndex) {
                [self decodeAudio:packet];
            }
            av_packet_unref(packet);
        }
        av_packet_free(&packet);
        
        @synchronized (self) {
            self.isBuffering = false;
            self.isPlaybackBufferFull = true;
            self.isPlaybackBufferEmpty = false;
//            printf("===\n END fillBuffer\n");
//            [self printBufferSizes];
        }
    });
}

- (void) clearBuffer: (NSMutableArray*) buffer {
    @synchronized (buffer) {
        for (int i = 0; i < [buffer count]; i++) {
            CMSampleBufferRef frame = [[buffer objectAtIndex:i] pointerValue];
            CFRelease(frame);
        }
        [buffer removeAllObjects];
    }
}

- (CVPixelBufferRef) convertToPixelBuffer: (AVFrame*) frame {
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        return (CVPixelBufferRef) frame->data[3];
    }
    
    // Define pixel format based on AVFrame (assuming it's YUV420)
    OSType pixelFormat = kCVPixelFormatType_420YpCbCr8Planar;

    // Create a CVPixelBuffer
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        frame->width,
        frame->height,
        pixelFormat,
        (__bridge CFDictionaryRef)@{
          (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        },
        &pixelBuffer
    );

    if (status != kCVReturnSuccess) {
        return NULL;
    }

    // Lock the pixel buffer for writing
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);

    // Access the base address and copy AVFrame's data (for planar YUV420P)
    uint8_t *yPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    uint8_t *uPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    uint8_t *vPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2);

    // Copy Y, U, V data from AVFrame to CVPixelBuffer planes
    memcpy(yPlane, frame->data[0], frame->linesize[0] * frame->height);
    memcpy(uPlane, frame->data[1], frame->linesize[1] * (frame->height / 2));
    memcpy(vPlane, frame->data[2], frame->linesize[2] * (frame->height / 2));

    // Unlock the pixel buffer
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    return pixelBuffer;
}

- (CMSampleBufferRef) createVideoSampleBuffer: (AVFrame *) frame fromStream: (AVStream *) stream {
    CVPixelBufferRef pixelBuffer = [self convertToPixelBuffer: frame];

    if (!pixelBuffer) {
        printf("Cannot create pixel buffer");
        return NULL;
    }
    
    CMSampleBufferRef sampleBuffer;
    CMFormatDescriptionRef formatDescription;
    
    int status = CMVideoFormatDescriptionCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        &formatDescription
    );
    
    if (status != kCVReturnSuccess || !formatDescription) {
        printf("Cannot create format description");
        return NULL;
    }
    
    CMSampleTimingInfo timingInfo = {
        .presentationTimeStamp = CMTimeMake(frame->pts /* * stream->time_base.num */, stream->time_base.den),
        .duration = CMTimeMake(1, stream->avg_frame_rate.num),
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    OSStatus result = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        formatDescription,
        &timingInfo,
        &sampleBuffer
    );
    
    if (result != noErr || !sampleBuffer) {
        printf("Cannot create sample buffer");
        CFRelease(formatDescription);
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    
    CFRelease(formatDescription);
//    CVPixelBufferRelease(pixelBuffer);
    
    return sampleBuffer;
}

- (CMSampleBufferRef) createAudioSampleBuffer: (AVFrame *) frame fromStream: (AVStream *) stream {
    // AVFrame->format is AV_SAMPLE_FMT_FLTP
    
    uint8_t **audioData;
    int audioDataSize;
    av_samples_alloc_array_and_samples(&audioData, &audioDataSize, frame->channels, frame->nb_samples, AV_SAMPLE_FMT_S16, 0);
    swr_convert(_swrCtx, audioData, frame->nb_samples, (const uint8_t **)frame->data, frame->nb_samples);
    
    OSStatus status;
    
    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate = frame->sample_rate;
    audioFormat.mChannelsPerFrame = frame->channels;
    audioFormat.mBitsPerChannel = sizeof(int16_t) * 8 /* 1 byte */;
    audioFormat.mBytesPerPacket = audioFormat.mChannelsPerFrame * sizeof(int16_t);
    audioFormat.mFramesPerPacket = 1 /* always 1 for PCM */;
    audioFormat.mBytesPerFrame = audioFormat.mBytesPerPacket;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    
    CMFormatDescriptionRef formatDescription;
    status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &audioFormat, 0, NULL, 0, NULL, NULL, &formatDescription);
    
    if (status != noErr || !formatDescription) {
        printf("Cannot create format description\n");

        CFRelease(formatDescription);
        free(audioData[0]);
        free(audioData);

        return NULL;
    }
    
    CMBlockBufferRef blockBuffer;
    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, audioData[0], audioDataSize, kCFAllocatorNull, NULL, 0, audioDataSize, 0, &blockBuffer);

    if (status != kCMBlockBufferNoErr || !blockBuffer) {
        printf("Cannot create block buffer\n");
        
        CFRelease(formatDescription);
        free(audioData[0]);
        free(audioData);

        return NULL;
    }
    
    CMSampleTimingInfo timingInfo = {
        .presentationTimeStamp = CMTimeMake(frame->pts /* * stream->time_base.num */, stream->time_base.den),
        .duration = CMTimeMake(frame->nb_samples, frame->sample_rate),
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    CMSampleBufferRef sampleBuffer;
    status = CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, true, NULL, NULL, formatDescription, 1, 1, &timingInfo, 0, NULL, &sampleBuffer);
    
    CFRelease(blockBuffer);
    CFRelease(formatDescription);

    if (status != noErr || !sampleBuffer) {
        printf("Cannot create sample buffer\n");

        return NULL;
    }

    return sampleBuffer;
}

- (AVCodecContext *) openCodecCtx: (AVCodecParameters *) codecpar {
    int err;
    
    const AVCodec *codec = avcodec_find_decoder(codecpar->codec_id);
    
    if (!codec) {
        av_log(NULL, AV_LOG_ERROR, "Could not find a decoder for the codec.\n");
        return NULL;
    }

    AVCodecContext *codecCtx = avcodec_alloc_context3(codec);
    if (!codecCtx) {
        av_log(NULL, AV_LOG_ERROR, "Could not allocate a codec context.\n");
        return NULL;
    }
    
    err = avcodec_parameters_to_context(codecCtx, codecpar);
    if (err < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not copy codec parameters to codec context.\n%s\n", av_err2str(err));
        avcodec_free_context(&codecCtx);
        return NULL;
    }
    
    #if TARGET_IPHONE_SIMULATOR
    #else
    if (codecCtx && codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
        AVBufferRef *hw_device_ctx = NULL;
        if (av_hwdevice_ctx_create(&hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) < 0) {
            fprintf(stderr, "Failed to create VideoToolbox device context\n");
        }
        codecCtx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
        codecCtx->get_format = get_hw_format;
        av_opt_set_int(codecCtx, "refcounted_frames", 1, 0);
    }
    #endif
    
    err = avcodec_open2(codecCtx, codec, NULL);
    if (err < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not open codec.\n%s\n", av_err2str(err));
        avcodec_free_context(&codecCtx);
        return NULL;
    }
    
    return codecCtx;
}

- (void) initCodecs {
    if (_videoStreamIndex >= 0) {
        _videoCodecCtx = [self openCodecCtx: _fmtCtx->streams[_videoStreamIndex]->codecpar];
        if (!_videoCodecCtx) {
            avformat_close_input(&_fmtCtx);
        }
    }
    if (_audioStreamIndex >= 0) {
        _audioCodecCtx = [self openCodecCtx: _fmtCtx->streams[_audioStreamIndex]->codecpar];
        if (!_audioCodecCtx) {
            avformat_close_input(&_fmtCtx);
        }
    }
}

- (void) deinitCodecs {
    #if TARGET_IPHONE_SIMULATOR
    #else
    if (_videoCodecCtx->hw_device_ctx) {
        av_buffer_unref(&_videoCodecCtx->hw_device_ctx);
    }
    #endif
    avcodec_free_context(&_videoCodecCtx);
    avcodec_free_context(&_audioCodecCtx);
}

- (void) printVersions {
    unsigned libavformat_version = avformat_version();
    unsigned libavcodec_version = avcodec_version();
    unsigned libavutil_version = avutil_version();

    printf("libavformat version: %u.%u.%u\n",
           (libavformat_version >> 16) & 0xFF,
           (libavformat_version >> 8) & 0xFF,
           libavformat_version & 0xFF);

    printf("libavcodec version: %u.%u.%u\n",
           (libavcodec_version >> 16) & 0xFF,
           (libavcodec_version >> 8) & 0xFF,
           libavcodec_version & 0xFF);

    printf("libavutil version: %u.%u.%u\n",
           (libavutil_version >> 16) & 0xFF,
           (libavutil_version >> 8) & 0xFF,
           libavutil_version & 0xFF);
}
 
- (void) dealloc {
    [self deinitCodecs];
    if (_swrCtx) {
        swr_free(&_swrCtx);
    }
    avformat_close_input(&_fmtCtx);

    [self clearBuffer:_readyVideoFramesBuffer];
    [self clearBuffer:_readyAudioFramesBuffer];
}

@end
