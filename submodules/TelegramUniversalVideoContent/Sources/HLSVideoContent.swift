import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AVFoundation
import UniversalMediaPlayer
import TelegramAudio
import AccountContext
import PhotoResources
import RangeSet
import TelegramVoip
import ManagedFile
import FFMpegBinding

public final class HLSVideoContent: UniversalVideoContent {
    public let id: AnyHashable
    public let nativeId: PlatformVideoContentId
    let userLocation: MediaResourceUserLocation
    public let fileReference: FileMediaReference
    public let dimensions: CGSize
    public let duration: Double
    let streamVideo: Bool
    let loopVideo: Bool
    let enableSound: Bool
    let baseRate: Double
    let fetchAutomatically: Bool
    
    public init(id: PlatformVideoContentId, userLocation: MediaResourceUserLocation, fileReference: FileMediaReference, streamVideo: Bool = false, loopVideo: Bool = false, enableSound: Bool = true, baseRate: Double = 1.0, fetchAutomatically: Bool = true) {
        self.id = id
        self.userLocation = userLocation
        self.nativeId = id
        self.fileReference = fileReference
        self.dimensions = self.fileReference.media.dimensions?.cgSize ?? CGSize(width: 480, height: 320)
        self.duration = self.fileReference.media.duration ?? 0.0
        self.streamVideo = streamVideo
        self.loopVideo = loopVideo
        self.enableSound = enableSound
        self.baseRate = baseRate
        self.fetchAutomatically = fetchAutomatically
    }
    
    public func makeContentNode(accountId: AccountRecordId, postbox: Postbox, audioSession: ManagedAudioSession) -> UniversalVideoContentNode & ASDisplayNode {
        return HLSVideoContentNode(accountId: accountId, postbox: postbox, audioSessionManager: audioSession, userLocation: self.userLocation, fileReference: self.fileReference, streamVideo: self.streamVideo, loopVideo: self.loopVideo, enableSound: self.enableSound, baseRate: self.baseRate, fetchAutomatically: self.fetchAutomatically)
    }
    
    public func isEqual(to other: UniversalVideoContent) -> Bool {
        if let other = other as? HLSVideoContent {
            if case let .message(_, stableId, _) = self.nativeId {
                if case .message(_, stableId, _) = other.nativeId {
                    if self.fileReference.media.isInstantVideo {
                        return true
                    }
                }
            }
        }
        return false
    }
}

private final class HLSVideoContentNode: ASDisplayNode, UniversalVideoContentNode {
    private final class HLSServerSource: SharedHLSServer.Source {
        let id: String
        let postbox: Postbox
        let userLocation: MediaResourceUserLocation
        let playlistFiles: [Int: FileMediaReference]
        let qualityFiles: [Int: FileMediaReference]
        
        private var playlistFetchDisposables: [Int: Disposable] = [:]
        
        init(accountId: Int64, fileId: Int64, postbox: Postbox, userLocation: MediaResourceUserLocation, playlistFiles: [Int: FileMediaReference], qualityFiles: [Int: FileMediaReference]) {
            self.id = "\(UInt64(bitPattern: accountId))_\(fileId)"
            self.postbox = postbox
            self.userLocation = userLocation
            self.playlistFiles = playlistFiles
            self.qualityFiles = qualityFiles
        }
        
        deinit {
            for (_, disposable) in self.playlistFetchDisposables {
                disposable.dispose()
            }
        }
        
        func masterPlaylistData() -> Signal<String, NoError> {
            var playlistString: String = ""
            playlistString.append("#EXTM3U\n")
            
            for (quality, file) in self.qualityFiles.sorted(by: { $0.key > $1.key }) {
                let width = file.media.dimensions?.width ?? 1280
                let height = file.media.dimensions?.height ?? 720
                
                let bandwidth: Int
                if let size = file.media.size, let duration = file.media.duration, duration != 0.0 {
                    bandwidth = Int(Double(size) / duration) * 8
                } else {
                    bandwidth = 1000000
                }
                
                playlistString.append("#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(width)x\(height)\n")
                playlistString.append("hls_level_\(quality).m3u8\n")
            }
            return .single(playlistString)
        }
        
        func playlistData(quality: Int) -> Signal<String, NoError> {
            guard let playlistFile = self.playlistFiles[quality] else {
                return .never()
            }
            if self.playlistFetchDisposables[quality] == nil {
                self.playlistFetchDisposables[quality] = freeMediaFileResourceInteractiveFetched(postbox: self.postbox, userLocation: self.userLocation, fileReference: playlistFile, resource: playlistFile.media.resource).startStrict()
            }
            
            return self.postbox.mediaBox.resourceData(playlistFile.media.resource)
            |> filter { data in
                return data.complete
            }
            |> map { data -> String in
                guard data.complete else {
                    return ""
                }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: data.path)) else {
                    return ""
                }
                guard var playlistString = String(data: data, encoding: .utf8) else {
                    return ""
                }
                let partRegex = try! NSRegularExpression(pattern: "mtproto:([\\d]+)", options: [])
                let results = partRegex.matches(in: playlistString, range: NSRange(playlistString.startIndex..., in: playlistString))
                for result in results.reversed() {
                    if let range = Range(result.range, in: playlistString) {
                        if let fileIdRange = Range(result.range(at: 1), in: playlistString) {
                            let fileId = String(playlistString[fileIdRange])
                            playlistString.replaceSubrange(range, with: "partfile\(fileId).mp4")
                        }
                    }
                }
                return playlistString
            }
        }
        
        func partData(index: Int, quality: Int) -> Signal<Data?, NoError> {
            return .never()
        }
        
        func fileData(id: Int64, range: Range<Int>) -> Signal<(TempBoxFile, Range<Int>, Int)?, NoError> {
            guard let (quality, file) = self.qualityFiles.first(where: { $0.value.media.fileId.id == id }) else {
                return .single(nil)
            }
            let _ = quality
            guard let size = file.media.size else {
                return .single(nil)
            }
            
            let postbox = self.postbox
            let userLocation = self.userLocation
            
            let mappedRange: Range<Int64> = Int64(range.lowerBound) ..< Int64(range.upperBound)
            
            let queue = postbox.mediaBox.dataQueue
            return Signal<(TempBoxFile, Range<Int>, Int)?, NoError> { subscriber in
                guard let fetchResource = postbox.mediaBox.fetchResource else {
                    return EmptyDisposable
                }
                
                let location = MediaResourceStorageLocation(userLocation: userLocation, reference: file.resourceReference(file.media.resource))
                let params = MediaResourceFetchParameters(
                    tag: TelegramMediaResourceFetchTag(statsCategory: .video, userContentType: .video),
                    info: TelegramCloudMediaResourceFetchInfo(reference: file.resourceReference(file.media.resource), preferBackgroundReferenceRevalidation: true, continueInBackground: true),
                    location: location,
                    contentType: .video,
                    isRandomAccessAllowed: true
                )
                
                let completeFile = TempBox.shared.tempFile(fileName: "data")
                let partialFile = TempBox.shared.tempFile(fileName: "data")
                let metaFile = TempBox.shared.tempFile(fileName: "data")
                
                guard let fileContext = MediaBoxFileContextV2Impl(
                    queue: queue,
                    manager: postbox.mediaBox.dataFileManager,
                    storageBox: nil,
                    resourceId: file.media.resource.id.stringRepresentation.data(using: .utf8)!,
                    path: completeFile.path,
                    partialPath: partialFile.path,
                    metaPath: metaFile.path
                ) else {
                    return EmptyDisposable
                }
                
                let fetchDisposable = fileContext.fetched(
                    range: mappedRange,
                    priority: .default,
                    fetch: { intervals in
                        return fetchResource(file.media.resource, intervals, params)
                    },
                    error: { _ in
                    },
                    completed: {
                    }
                )
                
                #if DEBUG
                let startTime = CFAbsoluteTimeGetCurrent()
                #endif
                
                let dataDisposable = fileContext.data(
                    range: mappedRange,
                    waitUntilAfterInitialFetch: true,
                    next: { result in
                        if result.complete {
                            #if DEBUG
                            let fetchTime = CFAbsoluteTimeGetCurrent() - startTime
                            print("Fetching \(quality)p part took \(fetchTime * 1000.0) ms")
                            #endif
                            subscriber.putNext((partialFile, Int(result.offset) ..< Int(result.offset + result.size), Int(size)))
                            subscriber.putCompletion()
                        }
                    }
                )
                
                return ActionDisposable {
                    queue.async {
                        fetchDisposable.dispose()
                        dataDisposable.dispose()
                        fileContext.cancelFullRangeFetches()
                        
                        TempBox.shared.dispose(completeFile)
                        TempBox.shared.dispose(metaFile)
                    }
                }
            }
            |> runOn(queue)
        }
    }
    
    private let postbox: Postbox
    private let userLocation: MediaResourceUserLocation
    private let fileReference: FileMediaReference
    private let approximateDuration: Double
    private let intrinsicDimensions: CGSize
    
    private let audioSessionManager: ManagedAudioSession
    private let audioSessionDisposable = MetaDisposable()
    private var hasAudioSession = false
    
    private let playbackCompletedListeners = Bag<() -> Void>()
    
    private var initializedStatus = false
    private var statusValue = MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: CGSize(), timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true)
    private var baseRate: Double = 1.0
    private var isBuffering = false
    private var seekId: Int = 0
    private let _status = ValuePromise<MediaPlayerStatus>()
    var status: Signal<MediaPlayerStatus, NoError> {
        return self._status.get()
    }
    
    private let _bufferingStatus = Promise<(RangeSet<Int64>, Int64)?>()
    var bufferingStatus: Signal<(RangeSet<Int64>, Int64)?, NoError> {
        return self._bufferingStatus.get()
    }
    
    private let _ready = Promise<Void>()
    var ready: Signal<Void, NoError> {
        return self._ready.get()
    }
    
    private let _preloadCompleted = ValuePromise<Bool>()
    var preloadCompleted: Signal<Bool, NoError> {
        return self._preloadCompleted.get()
    }
    
    private var playerSource: HLSServerSource?
    private var serverDisposable: Disposable?
    
    private let imageNode: TransformImageNode
    
    private var loadProgressDisposable: Disposable?
    private var statusDisposable: Disposable?
    
    private let fetchDisposable = MetaDisposable()
    
    private var dimensions: CGSize?
    private let dimensionsPromise = ValuePromise<CGSize>(CGSize())
    
    private var validLayout: CGSize?
    
    private var statusTimer: Foundation.Timer?
    
    private var preferredVideoQuality: UniversalVideoContentVideoQuality = .auto
    
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let videoLayer = AVSampleBufferDisplayLayer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    
    private let videoNode = ASDisplayNode()
    
    private let hlsClient = FFMpegHLS()
    private let videoQueue = DispatchQueue(label: "hls.video.queue")
    
    private var isPlaying = false
    private var isPlayerReady = false
    
    private var playbackEndObserver: Any?
    
    init(accountId: AccountRecordId, postbox: Postbox, audioSessionManager: ManagedAudioSession, userLocation: MediaResourceUserLocation, fileReference: FileMediaReference, streamVideo: Bool, loopVideo: Bool, enableSound: Bool, baseRate: Double, fetchAutomatically: Bool) {

        self.postbox = postbox
        self.fileReference = fileReference
        self.approximateDuration = fileReference.media.duration ?? 0.0
        self.audioSessionManager = audioSessionManager
        self.userLocation = userLocation
        self.baseRate = baseRate
        
        if var dimensions = fileReference.media.dimensions {
            if let thumbnail = fileReference.media.previewRepresentations.first {
                let dimensionsVertical = dimensions.width < dimensions.height
                let thumbnailVertical = thumbnail.dimensions.width < thumbnail.dimensions.height
                if dimensionsVertical != thumbnailVertical {
                    dimensions = PixelDimensions(width: dimensions.height, height: dimensions.width)
                }
            }
            self.dimensions = dimensions.cgSize
        } else {
            self.dimensions = CGSize(width: 128.0, height: 128.0)
        }
        
        self.imageNode = TransformImageNode()
        
        if !enableSound {
            audioRenderer.volume = 0.0
        }
        
        self.intrinsicDimensions = fileReference.media.dimensions?.cgSize ?? CGSize(width: 480.0, height: 320.0)
        
        var qualityFiles: [Int: FileMediaReference] = [:]
        for alternativeRepresentation in fileReference.media.alternativeRepresentations {
            if let alternativeFile = alternativeRepresentation as? TelegramMediaFile {
                for attribute in alternativeFile.attributes {
                    if case let .Video(_, size, _, _, _, videoCodec) = attribute {
                        let _ = size
                        if let videoCodec, NativeVideoContent.isVideoCodecSupported(videoCodec: videoCodec) {
                            qualityFiles[Int(size.height)] = fileReference.withMedia(alternativeFile)
                        }
                    }
                }
            }
        }
        /*for key in Array(qualityFiles.keys) {
            if key != 144 && key != 720 {
                qualityFiles.removeValue(forKey: key)
            }
        }*/
        var playlistFiles: [Int: FileMediaReference] = [:]
        for alternativeRepresentation in fileReference.media.alternativeRepresentations {
            if let alternativeFile = alternativeRepresentation as? TelegramMediaFile {
                if alternativeFile.mimeType == "application/x-mpegurl" {
                    if let fileName = alternativeFile.fileName {
                        if fileName.hasPrefix("mtproto:") {
                            let fileIdString = String(fileName[fileName.index(fileName.startIndex, offsetBy: "mtproto:".count)...])
                            if let fileId = Int64(fileIdString) {
                                for (quality, file) in qualityFiles {
                                    if file.media.fileId.id == fileId {
                                        playlistFiles[quality] = fileReference.withMedia(alternativeFile)
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if !playlistFiles.isEmpty && playlistFiles.keys == qualityFiles.keys {
            self.playerSource = HLSServerSource(accountId: accountId.int64, fileId: fileReference.media.fileId.id, postbox: postbox, userLocation: userLocation, playlistFiles: playlistFiles, qualityFiles: qualityFiles)
        }
        
        super.init()

        self.imageNode.setSignal(internalMediaGridMessageVideo(postbox: postbox, userLocation: self.userLocation, videoReference: fileReference) |> map { [weak self] getSize, getData in
            Queue.mainQueue().async {
                if let strongSelf = self, strongSelf.dimensions == nil {
                    if let dimensions = getSize() {
                        strongSelf.dimensions = dimensions
                        strongSelf.dimensionsPromise.set(dimensions)
                        if let size = strongSelf.validLayout {
                            strongSelf.updateLayout(size: size, transition: .immediate)
                        }
                    }
                }
            }
            return getData
        })
        
        self.videoNode.frame = CGRect(origin: CGPoint(), size: self.intrinsicDimensions)
        
        self.videoNode.setLayerBlock {
            return self.videoLayer
        }
        
        self.videoLayer.videoGravity = .resizeAspect
        
        self.synchronizer.addRenderer(audioRenderer)
        self.synchronizer.addRenderer(self.videoLayer)
        
        self.synchronizer.rate = 0.0
        CMTimebaseSetTime(self.synchronizer.timebase, time: CMTime(value: 0, timescale: 0))
        
        self.addSubnode(self.imageNode)
        self.addSubnode(self.videoNode)
        
        self.imageNode.imageUpdated = { [weak self] _ in
            self?._ready.set(.single(Void()))
        }
        
        self.synchronizer.addObserver(self, forKeyPath: "rate", options: [], context: nil)
        
        self._bufferingStatus.set(.single(nil))
        
        if let playerSource = self.playerSource {
            self.serverDisposable = SharedHLSServer.shared.registerPlayer(source: playerSource, completion: { [weak self] in
                Queue.mainQueue().async {
                    guard let self else {
                        return
                    }
                    
                    let assetUrl = "http://127.0.0.1:\(SharedHLSServer.shared.port)/\(playerSource.id)/master.m3u8"
                    
                    self.setupPlaybackEndObserver()
                    
                    if let (_, _, available) = self.videoQualityState() {
                        self.hlsClient.setupAvailableQualities(available.map { NSNumber(value: $0) })
                    }
                    
                    self.hlsClient.addObserver(self, forKeyPath: "playbackBufferEmpty", options: .new, context: nil)
                    self.hlsClient.addObserver(self, forKeyPath: "playbackBufferFull", options: .new, context: nil)
                    
                    self.videoQueue.async {
                        self.hlsClient.open(assetUrl)
                        self.isPlayerReady = true
                    }
                    
                    #if DEBUG
                    print("HLSVideoContentNode: playing \(assetUrl)")
                    #endif
                    
                    self.videoLayer.requestMediaDataWhenReady(on: self.videoQueue) {
                        while self.videoLayer.isReadyForMoreMediaData && self.hlsClient.hasMoreVideoFrames() {
                            let buffer = self.hlsClient.getNextVideoFrame()?.takeRetainedValue()
                            if let buffer = buffer {
                                self.videoLayer.enqueue(buffer)
                            }
                        }
                    }
                    
                    self.audioRenderer.requestMediaDataWhenReady(on: self.videoQueue) {
                        while self.audioRenderer.isReadyForMoreMediaData && self.hlsClient.hasMoreAudioFrames() {
                            let buffer = self.hlsClient.getNextAudioFrame()?.takeRetainedValue()
                            if let buffer = buffer {
                                self.audioRenderer.enqueue(buffer)
                            }
                        }
                    }
                }
            })
        }
    }
    
    deinit {
        if let observer = self.playbackEndObserver {
            self.synchronizer.removeTimeObserver(observer)
        }
        
        self.synchronizer.removeObserver(self, forKeyPath: "rate")
        self.hlsClient.removeObserver(self, forKeyPath: "playbackBufferEmpty")
        self.hlsClient.removeObserver(self, forKeyPath: "playbackBufferFull")
        
        self.videoLayer.stopRequestingMediaData()
        self.audioRenderer.stopRequestingMediaData()
        
        self.audioSessionDisposable.dispose()
        
        self.serverDisposable?.dispose()
        
        self.statusTimer?.invalidate()
    }
    
    private func setupPlaybackEndObserver() {
        self.playbackEndObserver = self.synchronizer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: self.approximateDuration, preferredTimescale: 1))],
            queue: self.videoQueue
        ) {
            self.synchronizer.rate = 0.0
            self.isPlaying = false
            self.performActionAtEnd()
        }
    }
    
    private func updateStatus() {
        let isPlaying = !self.synchronizer.rate.isZero
        let status: MediaPlayerPlaybackStatus
        if self.isBuffering {
            status = .buffering(initial: false, whilePlaying: isPlaying, progress: 0.0, display: true)
        } else {
            status = isPlaying ? .playing : .paused
        }
        var timestamp = self.synchronizer.currentTime().seconds
        if timestamp.isFinite && !timestamp.isNaN {
        } else {
            timestamp = 0.0
        }
        self.statusValue = MediaPlayerStatus(generationTimestamp: CACurrentMediaTime(), duration: Double(self.approximateDuration), dimensions: CGSize(), timestamp: timestamp, baseRate: self.baseRate, seekId: self.seekId, status: status, soundEnabled: true)
        self._status.set(self.statusValue)
        
        if case .playing = status {
            if self.statusTimer == nil {
                self.statusTimer = Foundation.Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true, block: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.updateStatus()
                })
            }
        } else if let statusTimer = self.statusTimer {
            self.statusTimer = nil
            statusTimer.invalidate()
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "rate" {
            let isPlaying = !self.synchronizer.rate.isZero
            if isPlaying {
                self.isBuffering = false
            }
            self.updateStatus()
        } else if keyPath == "playbackBufferEmpty" {
            if let isEmpty = change?[.newKey] as? Bool, isEmpty && !self.hlsClient.finished() {
                self.isBuffering = true
                self.synchronizer.rate = 0.0
                self.updateStatus()
            }
        } else if keyPath == "playbackLikelyToKeepUp" || keyPath == "playbackBufferFull" {
            if let isFull = change?[.newKey] as? Bool, isFull {
                self.isBuffering = false
                if (self.isPlaying && self.synchronizer.rate.isZero) {
                    // if not paused, restore rate
                    self.synchronizer.rate = Float(baseRate)
                }
                self.updateStatus()
            }
        }
    }
    
    private func performActionAtEnd() {
        for listener in self.playbackCompletedListeners.copyItems() {
            listener()
        }
    }
    
    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        transition.updatePosition(node: self.videoNode, position: CGPoint(x: size.width / 2.0, y: size.height / 2.0))
        transition.updateTransformScale(node: self.videoNode, scale: size.width / self.intrinsicDimensions.width)
        
        transition.updateFrame(node: self.imageNode, frame: CGRect(origin: CGPoint(), size: size))
        
        if let dimensions = self.dimensions {
            let imageSize = CGSize(width: floor(dimensions.width / 2.0), height: floor(dimensions.height / 2.0))
            let makeLayout = self.imageNode.asyncLayout()
            let applyLayout = makeLayout(TransformImageArguments(corners: ImageCorners(), imageSize: imageSize, boundingSize: imageSize, intrinsicInsets: UIEdgeInsets(), emptyColor: .clear))
            applyLayout()
        }
    }
    
    func play() {
        assert(Queue.mainQueue().isCurrent())
        self.isPlaying = true
        if self.isPlayerReady {
            self.synchronizer.rate = Float(baseRate)
        }
        if !self.initializedStatus {
            self._status.set(MediaPlayerStatus(generationTimestamp: 0.0, duration: Double(self.approximateDuration), dimensions: CGSize(), timestamp: 0.0, baseRate: self.baseRate, seekId: self.seekId, status: .buffering(initial: true, whilePlaying: true, progress: 0.0, display: true), soundEnabled: true))
        }
        if !self.hasAudioSession {
            if self.audioRenderer.volume != 0.0 {
                self.audioSessionDisposable.set(self.audioSessionManager.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.hasAudioSession = true
                }, deactivate: { [weak self] _ in
                    guard let self else {
                        return .complete()
                    }
                    self.hasAudioSession = false
                    
                    return .complete()
                }))
            }
        }
    }
    
    func pause() {
        assert(Queue.mainQueue().isCurrent())
        self.isPlaying = false
        self.synchronizer.rate = 0.0
    }
    
    func togglePlayPause() {
        assert(Queue.mainQueue().isCurrent())
        
        if self.isPlaying {
            self.isPlaying = false
            self.synchronizer.rate = 0.0
        } else {
            self.isPlaying = true
            if self.isPlayerReady {
                self.synchronizer.rate = Float(self.baseRate)
            }
        }
    }
    
    func setSoundEnabled(_ value: Bool) {
        assert(Queue.mainQueue().isCurrent())
        if value {
            self.audioRenderer.volume = 1.0
            self.audioSessionDisposable.set(self.audioSessionManager.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak self] _ in
                self?.hasAudioSession = true
            }, deactivate: { [weak self] _ in
                self?.hasAudioSession = false
                return .complete()
            }))
        } else {
            self.audioRenderer.volume = 0.0
            self.hasAudioSession = false
            self.audioSessionDisposable.set(nil)
        }
    }
    
    func seek(_ timestamp: Double) {
        assert(Queue.mainQueue().isCurrent())
        self.seekId += 1
        let time = CMTime(seconds: timestamp, preferredTimescale: 30)
        self.synchronizer.setRate(0.0, time: time)
        self.hlsClient.seek(time)
        if (self.isPlaying) {
            self.synchronizer.setRate(Float(baseRate), time: time)
        }
        self.audioRenderer.flush()
        self.videoLayer.flush()
    }
    
    func playOnceWithSound(playAndRecord: Bool, seek: MediaPlayerSeek, actionAtEnd: MediaPlayerPlayOnceWithSoundActionAtEnd) {
        self.audioRenderer.volume = 1.0
        self.play()
    }
    
    func setSoundMuted(soundMuted: Bool) {
        self.audioRenderer.volume = soundMuted ? 0.0 : 1.0
    }
    
    func continueWithOverridingAmbientMode(isAmbient: Bool) {
    }
    
    func setForceAudioToSpeaker(_ forceAudioToSpeaker: Bool) {
    }
    
    func continuePlayingWithoutSound(actionAtEnd: MediaPlayerPlayOnceWithSoundActionAtEnd) {
        self.audioRenderer.volume = 0.0
        self.hasAudioSession = false
        self.audioSessionDisposable.set(nil)
    }
    
    func setContinuePlayingWithoutSoundOnLostAudioSession(_ value: Bool) {   
    }
    
    func setBaseRate(_ baseRate: Double) {
        if self.isPlayerReady {
            self.synchronizer.rate = Float(baseRate)
        }
        self.baseRate = baseRate
        self.updateStatus()
    }
    
    func setVideoQuality(_ videoQuality: UniversalVideoContentVideoQuality) {
        switch videoQuality {
        case .auto:
            self.hlsClient.quality = -1
        case let .quality(qualityValue):
            self.hlsClient.quality = qualityValue
        }
        
        self.preferredVideoQuality = videoQuality
    }
    
    func videoQualityState() -> (current: Int, preferred: UniversalVideoContentVideoQuality, available: [Int])? {
        guard let playerSource = self.playerSource else {
            return nil
        }
        let current = Int(self.videoLayer.frame.height)
        var available: [Int] = Array(playerSource.qualityFiles.keys)
        available.sort(by: { $0 > $1 })
        return (current, self.preferredVideoQuality, available)
    }
    
    func addPlaybackCompleted(_ f: @escaping () -> Void) -> Int {
        return self.playbackCompletedListeners.add(f)
    }
    
    func removePlaybackCompleted(_ index: Int) {
        self.playbackCompletedListeners.remove(index)
    }
    
    func fetchControl(_ control: UniversalVideoNodeFetchControl) {
    }
    
    func notifyPlaybackControlsHidden(_ hidden: Bool) {
    }

    func setCanPlaybackWithoutHierarchy(_ canPlaybackWithoutHierarchy: Bool) {
    }
}
