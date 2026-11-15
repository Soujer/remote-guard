import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

enum RecordingStorage {
    static let bitrate = 1_000_000
    static func duration(_ file: URL) -> Double? {
        guard let data = try? Vault.readBounded(file.appendingPathExtension("meta.json"), maximum: 4096),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], info["schema"] as? Int == 1,
              let seconds = info["durationSeconds"] as? Double, seconds.isFinite, seconds > 0, seconds <= 86400,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, info["bytes"] as? Int == size else { return nil }
        return seconds
    }
    static func saveDuration(_ file: URL, seconds: Double) throws {
        guard seconds.isFinite, seconds > 0, seconds <= 86400 else { return }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try JSONSerialization.data(withJSONObject: ["schema": 1, "durationSeconds": seconds, "bytes": size]).write(to: file.appendingPathExtension("meta.json"), options: .atomic)
    }
    static func clock(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "待读取" }
        let value = Int(seconds.rounded()); return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    static func files(_ directory: URL) throws -> [URL] {
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]).filter {
            let name = $0.lastPathComponent
            guard name.range(of: "^rg-[0-9]{8}T[0-9]{9}Z-[a-f0-9]{32}\\.rgrec(\\.partial)?$", options: .regularExpression) != nil else { return false }
            let info = try $0.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            return info.isRegularFile == true && info.isSymbolicLink != true
        }.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first < second
        }
    }
    static func prepare(_ settings: Settings, reserve: Int) throws {
        let directory = URL(fileURLWithPath: settings.directory, isDirectory: true)
        try ensureDirectory(directory)
        let limit = settings.quotaMB * 1_048_576
        try require(reserve <= limit, "单段录像预算超过存储上限")
        let files = try self.files(directory)
        var total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        for file in files where total + reserve > limit { let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0; try fm.removeItem(at: file); try? fm.removeItem(at: file.appendingPathExtension("meta.json")); total -= size }
        let free = (try fm.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        try require(free >= Int64(512 * 1_048_576 + reserve), "磁盘空间不足：录屏需预留 512 MB")
    }
    static func filename() -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return "rg-" + formatter.string(from: Date()) + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".rgrec"
    }
}
// AVAssetWriter emits fragmented MP4 bytes in memory; its file-writing initializer is never used.
final class SegmentEncoder: NSObject, AVAssetWriterDelegate {
    let asset: AVAssetWriter; let input: AVAssetWriterInput; let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let encrypted: RecordingWriter; private let lock = NSLock(); private var failure: Error?
    private var frames = 0
    private(set) var duration: Double = 0
    init(url: URL, publicKey: String, width: Int, height: Int, limit: Int) throws {
        encrypted = try RecordingWriter(url, publicKey: publicKey, limit: limit)
        asset = AVAssetWriter(contentType: .mpeg4Movie)
        asset.outputFileTypeProfile = .mpeg4AppleHLS
        asset.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        asset.initialSegmentStartTime = .zero
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: RecordingStorage.bitrate, AVVideoExpectedSourceFrameRateKey: 5, AVVideoMaxKeyFrameIntervalKey: 10, AVVideoAllowFrameReorderingKey: false]])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        super.init(); asset.delegate = self
        try require(asset.canAdd(input), "系统不支持此录屏编码配置"); asset.add(input)
        try require(asset.startWriting(), "无法启动系统视频编码器"); asset.startSession(atSourceTime: .zero)
    }
    func append(_ pixel: CVPixelBuffer, at seconds: Double) throws {
        lock.lock(); let error = failure; lock.unlock(); if let error { throw error }
        if asset.status == .failed { throw asset.error ?? GuardError.message("系统编码失败") }
        guard input.isReadyForMoreMediaData else { return }
        try require(adaptor.append(pixel, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)), "视频帧编码失败")
        frames += 1
        duration = seconds + 0.2
    }
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        do { try encrypted.write(data) } catch { failure = error }
    }
    func finish() throws {
        try require(frames > 0, "没有可录制的画面")
        asset.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600)); input.markAsFinished()
        let group = DispatchGroup(); group.enter(); asset.finishWriting { group.leave() }
        try require(group.wait(timeout: .now() + 20) == .success, "系统视频编码收尾超时")
        lock.lock(); defer { lock.unlock() }; if let failure { throw failure }
        try require(asset.status == .completed, "视频片段收尾失败")
        try encrypted.finish()
    }
    deinit { if asset.status == .writing { asset.cancelWriting() } }
}
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "com.soujer.remote-guard.capture")
    var onStatus: ((String, Bool) -> Void)?
    private var stream: SCStream?; private var timer: DispatchSourceTimer?; private var latest: CVPixelBuffer?
    private var encoder: SegmentEncoder?; private var settings = Settings(); private var partial: URL?
    private var began: UInt64 = 0; private var width = 0; private var height = 0; private var generation = 0; private var starting = false
    private func report(_ text: String, _ active: Bool) { logGuard(text); DispatchQueue.main.async { self.onStatus?(text, active) } }
    func start(_ settings: Settings) {
        queue.async {
            guard self.stream == nil && !self.starting else { return }
            guard CGPreflightScreenCaptureAccess() else { self.report("请先在录屏页面授权屏幕录制", false); return }
            self.starting = true; self.settings = settings; self.generation += 1; let request = self.generation
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                self.queue.async {
                    guard request == self.generation else { return }; self.starting = false
                    do {
                        guard let content, let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw error ?? GuardError.message("未找到可录制的显示器") }
                        // Resize only the captured video buffers; never change the display mode.
                        let scale = min(1, min(1920.0 / Double(display.width), 1080.0 / Double(display.height)))
                        self.width = max(2, Int(Double(display.width) * scale) / 2 * 2); self.height = max(2, Int(Double(display.height) * scale) / 2 * 2)
                        let configuration = SCStreamConfiguration(); configuration.width = self.width; configuration.height = self.height
                        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5); configuration.pixelFormat = kCVPixelFormatType_32BGRA
                        configuration.queueDepth = 3; configuration.capturesAudio = false; configuration.showsCursor = true
                        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == getpid() }, exceptingWindows: [])
                        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue); self.stream = stream
                        stream.startCapture { error in self.queue.async {
                            guard request == self.generation else { stream.stopCapture { _ in }; return }
                            if let error { self.stop(reason: "录屏启动失败：" + error.localizedDescription); return }
                            let timer = DispatchSource.makeTimerSource(queue: self.queue); timer.schedule(deadline: .now(), repeating: .milliseconds(200)); timer.setEventHandler { self.tick() }; self.timer = timer; timer.resume()
                            self.report("加密录屏进行中（主显示器，无声音）", true)
                        } }
                    } catch { self.report("录屏启动失败：" + error.localizedDescription, false); self.stream = nil }
                }
            }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, type == .screen, CMSampleBufferIsValid(sampleBuffer), let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latest = pixel
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { if self.stream === stream { self.stop(reason: "屏幕采集停止：" + error.localizedDescription) } } }
    private func tick() {
        guard let latest else { return }
        do {
            if encoder != nil && Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9 >= Double(settings.segmentSeconds) { try closeSegment() }
            if encoder == nil {
                let budget = Int(Double(settings.segmentSeconds) * Double(RecordingStorage.bitrate) / 8 * 1.25) + 2_097_152
                try RecordingStorage.prepare(settings, reserve: budget)
                let url = URL(fileURLWithPath: settings.directory).appendingPathComponent(RecordingStorage.filename() + ".partial")
                encoder = try SegmentEncoder(url: url, publicKey: settings.publicKey, width: width, height: height, limit: budget); partial = url; began = DispatchTime.now().uptimeNanoseconds
            }
            let free = (try fm.attributesOfFileSystem(forPath: settings.directory)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            try require(free > 512 * 1_048_576, "磁盘空间不足，已停止录屏")
            try encoder?.append(latest, at: Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9)
        } catch { stop(reason: "录屏停止：" + error.localizedDescription) }
    }
    private func closeSegment() throws {
        guard let encoder else { return }; defer { self.encoder = nil; partial = nil }
        try encoder.finish()
        if let partial { let final = partial.deletingPathExtension(); try fm.moveItem(at: partial, to: final); do { try RecordingStorage.saveDuration(final, seconds: encoder.duration) } catch { logGuard("时长记录失败：" + error.localizedDescription) }; logGuard("加密片段已保存：" + final.lastPathComponent) }
    }
    func stop(reason: String = "加密录屏待命", _ completion: (() -> Void)? = nil) {
        queue.async {
            self.generation += 1; self.starting = false; self.timer?.cancel(); self.timer = nil
            let stream = self.stream; self.stream = nil; stream?.stopCapture { _ in }
            var status = reason
            do { try self.closeSegment() } catch { status = "片段未完成：" + error.localizedDescription }
            logGuard(status); self.latest = nil; DispatchQueue.main.async { self.onStatus?(status, false); completion?() }
        }
    }
}
// Memory-backed URL loading allows AVPlayer to seek without ever writing a decrypted movie.
final class MemoryMovie: NSObject, AVAssetResourceLoaderDelegate {
    private var bytes: Data
    let asset: AVURLAsset
    init(_ bytes: Data) {
        self.bytes = bytes; asset = AVURLAsset(url: URL(string: "rgrec://" + UUID().uuidString + "/recording.mp4")!)
        super.init(); asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "com.soujer.remote-guard.playback"))
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest { info.contentType = UTType.mpeg4Movie.identifier; info.contentLength = Int64(bytes.count); info.isByteRangeAccessSupported = true }
        if let data = request.dataRequest {
            let offset = max(data.requestedOffset, data.currentOffset)
            guard offset >= 0 && offset <= Int64(bytes.count) else { request.finishLoading(with: GuardError.message("录像读取范围无效")); return true }
            let start = Int(offset), end = data.requestsAllDataToEndOfResource ? bytes.count : min(bytes.count, Int(data.requestedOffset) + data.requestedLength)
            if end > start { data.respond(with: bytes.subdata(in: start..<end)) }
        }
        request.finishLoading(); return true
    }
    deinit { bytes.resetBytes(in: 0..<bytes.count) }
}
