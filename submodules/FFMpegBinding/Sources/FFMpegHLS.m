#import <FFMpegBinding/FFMpegHLS.h>

#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>

#import "libavcodec/avcodec.h"
#import "libavformat/avformat.h"
#import "libavformat/avio.h"
#import "libavutil/avutil.h"
#import "libavutil/opt.h"
#include "libswresample/swresample.h"

#define BUFFER_SIZE_SECONDS 3

enum AVPixelFormat get_hw_format(AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts) {
    for (const enum AVPixelFormat *p = pix_fmts; *p != -1; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *p;
        }
    }
    fprintf(stderr, "Cannot find VideoToolbox pixel format\n");
    return AV_PIX_FMT_NONE;
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

@end

@implementation FFMpegHLS

@synthesize quality = _quality;

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
    // notify player
    self.isPlaybackBufferEmpty = true;
    
    [self printVersions];
    
    av_log_set_level(AV_LOG_INFO);
    
    const char* urlStr = [url UTF8String];
    
    _fmtCtx = NULL;
    int err = 0;
    
    err = avformat_open_input(&_fmtCtx, urlStr, NULL, NULL);
    if (err < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not open input file: %s\n%s\n", urlStr, av_err2str(err));
        return -1;
    }
    
    _hasMoreVideoFrames = true;
    _hasMoreAudioFrames = true;
    
    _videoStreamIndex = 0;
    _audioStreamIndex = 1;
    
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
    self.isStopDecodingRequested = true;
    dispatch_async(_decodingQueue, ^{
        int newVideoStreamIndex = -1;
        int newAudioStreamIndex = -1;
        NSInteger targetProgramIndex = [self.qualities indexOfObject:@(quality)];
        
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
    });
}

- (void) setupAvailableQualities:(NSArray<NSNumber *> *)qualities {
    self.qualities = qualities;
}

- (NSInteger) quality {
    return _quality;
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
        printf("===\n SEEK flush buffers\n");
        [self printBufferSizes];
        
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
