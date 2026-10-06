import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum JobStatus {
    case waiting, converting, done, failed
}

private struct ConversionJob: Identifiable {
    let id = UUID()
    let input: URL
    var output: URL?
    var progress = 0.0
    var status: JobStatus = .waiting
    var error = ""
    var stage = ""
    var sizeBytes: Int64 = 0
}

private struct VideoInfo {
    let width: Int
    let height: Int
    let fps: Double
    let duration: Double
}

private struct EncodingProfile {
    let name: String
    let longEdge: Int?
    let fps: Int?
    let perFramePalette: Bool
}

private enum ConversionFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

private struct SavedJob: Codable {
    let input: String
    let output: String?
    let error: String
    let success: Bool
    let sizeBytes: Int64?
    let profile: String?
}

private final class ConverterModel: ObservableObject {
    static let shared = ConverterModel()
    @Published var jobs: [ConversionJob] = []
    @Published var isDragging = false
    @Published var quality = 0
    @Published var playbackSpeed = 1.0
    @Published var speedMode = 0
    @Published var limitEnabled = false
    @Published var maxSizeMB = 10

    private let worker: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "video.to.gif.worker"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        return queue
    }()
    private let encoderSlots = DispatchSemaphore(value: min(64, max(2, ProcessInfo.processInfo.activeProcessorCount * min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))))
    private let accepted = Set(["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpeg", "mpg", "ts"])
    private let profiles = [
        EncodingProfile(name: "原尺寸 · 原帧率 · 每帧调色", longEdge: nil, fps: nil, perFramePalette: true),
        EncodingProfile(name: "原尺寸 · 原帧率", longEdge: nil, fps: nil, perFramePalette: false),
        EncodingProfile(name: "1440px · 25帧", longEdge: 1440, fps: 25, perFramePalette: false),
        EncodingProfile(name: "1080px · 24帧", longEdge: 1080, fps: 24, perFramePalette: false),
        EncodingProfile(name: "900px · 20帧", longEdge: 900, fps: 20, perFramePalette: false),
        EncodingProfile(name: "720px · 15帧", longEdge: 720, fps: 15, perFramePalette: false),
        EncodingProfile(name: "600px · 12帧", longEdge: 600, fps: 12, perFramePalette: false),
        EncodingProfile(name: "480px · 10帧", longEdge: 480, fps: 10, perFramePalette: false),
        EncodingProfile(name: "360px · 8帧", longEdge: 360, fps: 8, perFramePalette: false),
        EncodingProfile(name: "240px · 6帧", longEdge: 240, fps: 6, perFramePalette: false),
        EncodingProfile(name: "160px · 4帧", longEdge: 160, fps: 4, perFramePalette: false),
        EncodingProfile(name: "120px · 2帧", longEdge: 120, fps: 2, perFramePalette: false),
        EncodingProfile(name: "96px · 1帧", longEdge: 96, fps: 1, perFramePalette: false)
    ]

    private init() {
        if let data = UserDefaults.standard.data(forKey: "recentConversions"),
           let saved = try? JSONDecoder().decode([SavedJob].self, from: data) {
            jobs = saved.map { entry in
                var job = ConversionJob(input: URL(fileURLWithPath: entry.input))
                job.output = entry.output.map { URL(fileURLWithPath: $0) }
                job.error = entry.error
                job.status = entry.success ? .done : .failed
                job.progress = entry.success ? 1 : 0
                job.sizeBytes = entry.sizeBytes ?? 0
                job.stage = entry.profile ?? ""
                return job
            }
        }
    }

    var pendingCount: Int { jobs.filter { $0.status == .waiting }.count }

    func add(_ urls: [URL]) {
        DispatchQueue.main.async {
            for url in urls where url.isFileURL {
                self.jobs.insert(ConversionJob(input: url), at: 0)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func startPending() {
        let pending = jobs.filter { $0.status == .waiting }
        guard !pending.isEmpty else { return }
        let preset = quality
        let speed = playbackSpeed
        let selectedSpeedMode = speedMode
        let chosenMB = max(1, min(10_000, maxSizeMB))
        if limitEnabled { maxSizeMB = chosenMB }
        let sizeLimit = limitEnabled ? Int64(chosenMB) * 1_000_000 : nil
        for job in pending {
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            jobs[index].status = .converting
            jobs[index].stage = "排队中"
            worker.addOperation {
                self.convert(job.id, input: job.input, preset: preset, sizeLimit: sizeLimit, speed: speed, speedMode: selectedSpeedMode)
            }
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.status == .done || $0.status == .failed }
        saveHistory()
    }

    private func saveHistory() {
        let saved = jobs.filter { $0.status == .done || $0.status == .failed }.prefix(30).map {
            SavedJob(input: $0.input.path, output: $0.output?.path, error: $0.error, success: $0.status == .done, sizeBytes: $0.sizeBytes, profile: $0.stage)
        }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "recentConversions")
        }
    }

    private func update(_ id: UUID, _ change: @escaping (inout ConversionJob) -> Void) {
        DispatchQueue.main.async {
            guard let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            change(&self.jobs[index])
            if self.jobs[index].status == .done || self.jobs[index].status == .failed {
                self.saveHistory()
            }
        }
    }

    private func tool(_ name: String) -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let path = resources.appendingPathComponent("Tools/\(name)").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private func probe(_ input: URL, ffprobe: String) -> VideoInfo? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,avg_frame_rate", "-show_entries", "format=duration", "-of", "json", input.path]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stream = (json["streams"] as? [[String: Any]])?.first,
                  let width = stream["width"] as? Int,
                  let height = stream["height"] as? Int,
                  width > 0, height > 0 else { return nil }
            let rate = (stream["avg_frame_rate"] as? String ?? "30/1").split(separator: "/")
            let numerator = Double(rate.first ?? "30") ?? 30
            let denominator = rate.count > 1 ? (Double(rate[1]) ?? 1) : 1
            let fps = denominator > 0 ? numerator / denominator : 30
            let format = json["format"] as? [String: Any]
            let duration = Double(format?["duration"] as? String ?? "") ?? 0
            return VideoInfo(width: width, height: height, fps: fps, duration: duration)
        } catch { return nil }
    }

    private func filters(for profile: EncodingProfile, video: VideoInfo, speed: Double) -> String {
        var parts: [String] = []
        if let edge = profile.longEdge, max(video.width, video.height) > edge {
            let ratio = Double(edge) / Double(max(video.width, video.height))
            let width = max(2, Int((Double(video.width) * ratio / 2).rounded()) * 2)
            let height = max(2, Int((Double(video.height) * ratio / 2).rounded()) * 2)
            parts.append("scale=\(width):\(height):flags=lanczos")
        }
        if let fps = profile.fps, video.fps > Double(fps) + 0.01 {
            parts.append("fps=\(fps)")
        }
        if speed != 1 {
            parts.append("setpts=(PTS-STARTPTS)/\(speed)")
        }
        // Normalize timing for every speed, including 1x. Irregular 0.01 s GIF
        // delays can be clamped by viewers and make even a 1x export run slowly.
        parts.append("fps=\(String(format: "%.3f", normalizedFPS(for: profile, video: video, speed: speed)))")
        return parts.joined(separator: ",")
    }

    private func normalizedFPS(for profile: EncodingProfile, video: VideoInfo, speed: Double) -> Double {
        let encodedFPS = profile.fps.map { min(video.fps, Double($0)) } ?? video.fps
        return min(25.0, max(1.0, encodedFPS * speed))
    }

    private func runFFmpeg(_ ffmpeg: String, arguments: [String], id: UUID, duration: Double, progressStart: Double, progressSpan: Double) throws -> (Int32, String) {
        encoderSlots.wait()
        defer { encoderSlots.signal() }
        let process = Process()
        let progressPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-progress", "pipe:1", "-nostats"] + arguments
        process.standardOutput = progressPipe
        process.standardError = errorPipe
        try process.run()
        var pending = ""
        while true {
            let data = progressPipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending += String(decoding: data, as: UTF8.self)
            let lines = pending.components(separatedBy: "\n")
            pending = lines.last ?? ""
            for line in lines.dropLast() where duration > 0 && progressSpan > 0 {
                if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                    let value = Double(line.split(separator: "=").last ?? "") ?? 0
                    let fraction = min(1, max(0, value / 1_000_000 / duration))
                    update(id) { $0.progress = progressStart + progressSpan * fraction }
                }
            }
        }
        process.waitUntilExit()
        let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, message)
    }

    private func friendlyError(_ raw: String) -> String {
        if raw.contains("moov atom not found") || raw.contains("Invalid data found") {
            return "视频文件无效或已损坏，未生成 GIF。"
        }
        if raw.contains("Permission denied") || raw.contains("Operation not permitted") {
            return "无法写入原视频所在文件夹。请检查文件夹权限。"
        }
        if raw.contains("No space left on device") {
            return "磁盘空间不足，未生成 GIF。"
        }
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "转换失败，请检查视频是否可以正常播放。" : String(firstLine.prefix(220))
    }

    private func mergeGIFs(_ gifsicle: String, files: [URL], output: URL) throws {
        encoderSlots.wait()
        defer { encoderSlots.signal() }
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: gifsicle)
        process.arguments = ["--no-warnings", "--loopcount=0"] + files.map(\.path) + ["-o", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ConversionFailure.message(friendlyError(message))
        }
    }

    private func mergeGIFBlocks(files: [URL], output: URL) throws {
        func invalid() -> ConversionFailure { .message("并行 GIF 片段结构无效。") }
        guard !files.isEmpty, FileManager.default.createFile(atPath: output.path, contents: nil) else { throw invalid() }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var sharedHeader: Data?
        var sharedCanvas: Data?
        for (part, file) in files.enumerated() {
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            guard bytes.count >= 14, bytes[0..<6] == Data("GIF89a".utf8) else { throw invalid() }
            let packed = bytes[10]
            let colorBytes = packed & 0x80 == 0 ? 0 : 3 * (1 << (Int(packed & 7) + 1))
            let headerEnd = 13 + colorBytes
            guard headerEnd < bytes.count else { throw invalid() }
            let currentHeader = bytes.subdata(in: 6..<headerEnd)
            let currentCanvas = bytes.subdata(in: 6..<10)
            if let sharedCanvas {
                guard currentCanvas == sharedCanvas else { throw invalid() }
            } else {
                sharedHeader = currentHeader
                sharedCanvas = currentCanvas
                try writer.write(contentsOf: bytes[0..<headerEnd])
            }
            let needsLocalPalette = part > 0 && currentHeader != sharedHeader
            var position = headerEnd
            var sawImage = false
            var sawTrailer = false
            while position < bytes.count {
                let start = position
                let marker = bytes[position]
                position += 1
                if marker == 0x3b {
                    sawTrailer = true
                    break
                }
                if marker == 0x21 {
                    guard position < bytes.count else { throw invalid() }
                    let label = bytes[position]
                    position += 1
                    while true {
                        guard position < bytes.count else { throw invalid() }
                        let count = Int(bytes[position])
                        position += 1
                        if count == 0 { break }
                        guard position + count <= bytes.count else { throw invalid() }
                        position += count
                    }
                    // Keep the first loop extension; later segments must not restart it.
                    if part == 0 || label != 0xff {
                        try writer.write(contentsOf: bytes[start..<position])
                    }
                } else if marker == 0x2c {
                    guard position + 9 <= bytes.count else { throw invalid() }
                    if !sawImage {
                        guard bytes[position] == 0, bytes[position + 1] == 0,
                              bytes[position + 2] == 0, bytes[position + 3] == 0,
                              bytes[position + 4..<position + 8] == bytes[6..<10] else { throw invalid() }
                        sawImage = true
                    }
                    let imagePacked = bytes[position + 8]
                    let descriptorEnd = position + 9
                    position += 9
                    if imagePacked & 0x80 != 0 {
                        position += 3 * (1 << (Int(imagePacked & 7) + 1))
                    }
                    guard position < bytes.count else { throw invalid() }
                    position += 1 // LZW minimum code size
                    while true {
                        guard position < bytes.count else { throw invalid() }
                        let count = Int(bytes[position])
                        position += 1
                        if count == 0 { break }
                        guard position + count <= bytes.count else { throw invalid() }
                        position += count
                    }
                    if needsLocalPalette && imagePacked & 0x80 == 0 {
                        guard colorBytes > 0 else { throw invalid() }
                        var descriptor = bytes.subdata(in: start..<descriptorEnd)
                        descriptor[9] = (imagePacked & 0x78) | 0x80 | (packed & 0x07)
                        try writer.write(contentsOf: descriptor)
                        try writer.write(contentsOf: bytes[13..<headerEnd])
                        try writer.write(contentsOf: bytes[descriptorEnd..<position])
                    } else {
                        try writer.write(contentsOf: bytes[start..<position])
                    }
                } else {
                    throw invalid()
                }
            }
            guard sawImage, sawTrailer, position == bytes.count else { throw invalid() }
        }
        try writer.write(contentsOf: Data([0x3b]))
    }

    private func encodeParallel(ffmpeg: String, gifsicle: String, input: URL, palette: URL?,
                                outputOptions: [String], gif: URL, working: URL, index: Int,
                                id: UUID, video: VideoInfo, profile: EncodingProfile,
                                speed: Double, speedLabel: String, progressStart: Double) throws {
        let inputSecondsPerFrame = speed / normalizedFPS(for: profile, video: video, speed: speed)
        let lastFrameTime = max(0, video.duration - 1 / max(1, video.fps))
        let estimatedFrames = max(1, Int(floor(lastFrameTime / inputSecondsPerFrame)) + 1)
        let segmentCount = min(ProcessInfo.processInfo.activeProcessorCount, estimatedFrames)
        let framesPerSegment = max(1, Int(ceil(Double(estimatedFrames) / Double(segmentCount))))
        let segmentLength = Double(framesPerSegment) * inputSecondsPerFrame
        let segments = (0..<segmentCount).compactMap { part -> (Double, Double, URL)? in
            let start = Double(part) * segmentLength
            guard start < video.duration - 0.001 else { return nil }
            let length = min(segmentLength, video.duration - start)
            return (start, length, working.appendingPathComponent("part-\(index)-\(part).gif"))
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var firstError: Error?
        var completed = 0
        update(id) { $0.stage = "\(segments.count) 路并行转换中 · \(speedLabel)" }
        for segment in segments {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    let arguments = ["-ss", String(format: "%.6f", segment.0), "-t", String(format: "%.6f", segment.1),
                                     "-i", input.path] + (palette.map { ["-i", $0.path] } ?? []) + outputOptions + [segment.2.path]
                    let result = try self.runFFmpeg(ffmpeg, arguments: arguments, id: id, duration: 0, progressStart: 0, progressSpan: 0)
                    guard result.0 == 0 else { throw ConversionFailure.message(self.friendlyError(result.1)) }
                    lock.lock()
                    completed += 1
                    let fraction = Double(completed) / Double(segments.count)
                    lock.unlock()
                    self.update(id) { $0.progress = progressStart + (0.88 - progressStart) * fraction }
                } catch {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
            }
        }
        group.wait()
        if let firstError { throw firstError }
        update(id) { $0.stage = "正在无损拼接动画帧 · \(speedLabel)"; $0.progress = 0.9 }
        let pieces = segments.map(\.2)
        do {
            try mergeGIFBlocks(files: pieces, output: gif)
        } catch {
            try? FileManager.default.removeItem(at: gif)
            try mergeGIFs(gifsicle, files: pieces, output: gif)
        }
        update(id) { $0.progress = 0.99 }
        for segment in segments { try? FileManager.default.removeItem(at: segment.2) }
    }

    private func convert(_ id: UUID, input: URL, preset: Int, sizeLimit: Int64?, speed: Double, speedMode: Int) {
        update(id) { $0.status = .converting }
        guard accepted.contains(input.pathExtension.lowercased()) else {
            update(id) { $0.status = .failed; $0.error = "不支持此文件格式，请拖入视频文件。" }
            return
        }
        guard FileManager.default.fileExists(atPath: input.path) else {
            update(id) { $0.status = .failed; $0.error = "找不到原视频，可能已被移动。" }
            return
        }
        guard let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else {
            update(id) { $0.status = .failed; $0.error = "应用内转换组件缺失，请重新安装完整的应用。" }
            return
        }
        guard let video = probe(input, ffprobe: ffprobe) else {
            update(id) { $0.status = .failed; $0.error = "无法读取视频信息，文件可能已损坏。" }
            return
        }
        let expectedDuration = video.duration / speed
        let speedLabel = String(format: "%g×", speed)
        let working = FileManager.default.temporaryDirectory.appendingPathComponent("gif-convert-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: working) }

            var attempt = 0
            func encode(_ index: Int) throws -> (URL, Int64) {
                attempt += 1
                let profile = profiles[index]
                let prefix = filters(for: profile, video: video, speed: speed)
                let palette = working.appendingPathComponent("palette-\(index).png")
                let gif = working.appendingPathComponent("result-\(index).gif")
                let description = sizeLimit == nil ? "最高画质转换中 · \(speedLabel)" : "匹配 \(sizeLimit! / 1_000_000) MB 上限 · \(speedLabel) · 第 \(attempt) 次试算"
                update(id) { $0.stage = description; $0.progress = 0 }
                func writeGIF(palette: URL?, options: [String], progressStart: Double, minimumParallelDuration: Double) throws {
                    if video.duration >= minimumParallelDuration, let gifsicle = tool("gifsicle") {
                        do {
                            try encodeParallel(ffmpeg: ffmpeg, gifsicle: gifsicle, input: input, palette: palette,
                                               outputOptions: options, gif: gif, working: working, index: index,
                                               id: id, video: video, profile: profile, speed: speed,
                                               speedLabel: speedLabel, progressStart: progressStart)
                            return
                        } catch {
                            try? FileManager.default.removeItem(at: gif)
                            update(id) { $0.stage = "并行片段无法合并，正在单路重试 · \(speedLabel)"; $0.progress = progressStart }
                        }
                    }
                    let arguments = ["-i", input.path] + (palette.map { ["-i", $0.path] } ?? []) + options + [gif.path]
                    let result = try runFFmpeg(ffmpeg, arguments: arguments, id: id, duration: expectedDuration,
                                               progressStart: progressStart, progressSpan: 0.99 - progressStart)
                    guard result.0 == 0 else { throw ConversionFailure.message(friendlyError(result.1)) }
                }
                let outputTail = ["-map", "[out]", "-an", "-sn", "-dn", "-fps_mode", "passthrough", "-loop", "0", "-gifflags", "+transdiff", "-y"]
                if profile.perFramePalette {
                    let dither = speedMode == 1 ? "bayer:bayer_scale=5" : "sierra3"
                    let mapping = (prefix.isEmpty ? "[0:v]" : "[0:v]\(prefix),") + "split[a][b];[a]palettegen=stats_mode=single:reserve_transparent=0[p];[b][p]paletteuse=new=1:dither=\(dither)[out]"
                    try writeGIF(palette: nil, options: ["-filter_complex", mapping] + outputTail,
                                 progressStart: 0, minimumParallelDuration: 1.5)
                    let attributes = try FileManager.default.attributesOfItem(atPath: gif.path)
                    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    guard size > 0 else { throw ConversionFailure.message("未生成有效 GIF。") }
                    return (gif, size)
                }
                // A representative palette needs only a few frames each second. GIF
                // encoding still receives every frame at the selected resolution.
                let sampleRate = video.duration < 2 ? min(25.0, video.fps) : min(5.0, video.fps)
                let sampleEdge = min(960, profile.longEdge ?? 960)
                let sampleRatio = min(1.0, Double(sampleEdge) / Double(max(video.width, video.height)))
                let sampleWidth = max(2, Int((Double(video.width) * sampleRatio / 2).rounded()) * 2)
                let sampleHeight = max(2, Int((Double(video.height) * sampleRatio / 2).rounded()) * 2)
                let paletteFilter = "fps=\(String(format: "%.3f", max(1, sampleRate))),scale=\(sampleWidth):\(sampleHeight):flags=lanczos,palettegen=stats_mode=full:reserve_transparent=0"
                let paletteResult = try runFFmpeg(ffmpeg, arguments: ["-i", input.path, "-map", "0:v:0", "-vf", paletteFilter, "-frames:v", "1", "-update", "1", "-y", palette.path], id: id, duration: video.duration, progressStart: 0, progressSpan: 0.2)
                guard paletteResult.0 == 0 else { throw ConversionFailure.message(friendlyError(paletteResult.1)) }
                update(id) { $0.progress = 0.2 }
                let dither = speedMode == 1 ? "bayer:bayer_scale=5" : "sierra3"
                let mapping = prefix.isEmpty ? "[0:v][1:v]paletteuse=dither=\(dither):diff_mode=rectangle[out]" : "[0:v]\(prefix)[scaled];[scaled][1:v]paletteuse=dither=\(dither):diff_mode=rectangle[out]"
                try writeGIF(palette: palette, options: ["-filter_complex", mapping] + outputTail,
                             progressStart: 0.2, minimumParallelDuration: speedMode == 1 ? 2.5 : 1.5)
                try? FileManager.default.removeItem(at: palette)
                let attributes = try FileManager.default.attributesOfItem(atPath: gif.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { throw ConversionFailure.message("未生成有效 GIF。") }
                return (gif, size)
            }

            let starts = [2, 1, 0, 3, 5, 7]
            let start = starts[max(0, min(starts.count - 1, preset))]
            let first = try encode(start)
            var best: (index: Int, file: URL, size: Int64)?
            if sizeLimit == nil || first.1 <= sizeLimit! {
                best = (start, first.0, first.1)
            } else {
                try? FileManager.default.removeItem(at: first.0)
                var low = start + 1
                var high = profiles.count - 1
                while low <= high {
                    let middle = (low + high) / 2
                    let candidate = try encode(middle)
                    if candidate.1 <= sizeLimit! {
                        if let old = best { try? FileManager.default.removeItem(at: old.file) }
                        best = (middle, candidate.0, candidate.1)
                        high = middle - 1
                    } else {
                        try? FileManager.default.removeItem(at: candidate.0)
                        low = middle + 1
                    }
                }
            }
            guard let chosen = best else {
                throw ConversionFailure.message("整段视频无法压到 \(sizeLimit! / 1_000_000) MB 以内。请提高上限或截短视频。")
            }
            let folder = input.deletingLastPathComponent()
            let originalStem = input.deletingPathExtension().lastPathComponent
            let chosenProfile = profiles[chosen.index]
            let colorMode = chosenProfile.perFramePalette ? "原画" : "流畅"
            let sizeMode = chosenProfile.longEdge.map { "\($0)px" } ?? "原尺寸"
            let stem = "\(originalStem)-\(String(format: "%g", speed))x-\(sizeMode)-\(colorMode)"
            var output = folder.appendingPathComponent(stem + ".gif")
            var number = 2
            while FileManager.default.fileExists(atPath: output.path) {
                output = folder.appendingPathComponent("\(stem)-\(number).gif")
                number += 1
            }
            try FileManager.default.moveItem(at: chosen.file, to: output)
            let selectedProfile = profiles[chosen.index]
            let encodedFPS = selectedProfile.fps.map { min(video.fps, Double($0)) } ?? video.fps
            let playbackFPS = min(25.0, max(1.0, encodedFPS * speed))
            let sizeName = selectedProfile.longEdge.map { "\($0)px" } ?? "原尺寸"
            let paletteName = selectedProfile.perFramePalette ? " · 每帧调色" : ""
            let chosenName = "\(sizeName) · \(String(format: "%g", playbackFPS)) 帧/秒\(paletteName) · \(speedLabel)"
            update(id) { $0.status = .done; $0.progress = 1; $0.output = output; $0.sizeBytes = chosen.size; $0.stage = chosenName }
        } catch {
            update(id) { $0.status = .failed; $0.error = error.localizedDescription }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        ConverterModel.shared.add(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        ConverterModel.shared.add([URL(fileURLWithPath: filename)])
        return true
    }
}

private struct ContentView: View {
    @ObservedObject private var model = ConverterModel.shared
    @State private var showingPicker = false

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.075, blue: 0.11).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                header
                dropZone
                settingsPanel
                startBar
                HStack {
                    Text("最近转换")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("\(model.jobs.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.cyan.opacity(0.12), in: Capsule())
                    Spacer()
                    if model.jobs.contains(where: { $0.status == .done || $0.status == .failed }) {
                        Button("清除记录") { model.clearFinished() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.035))
                    if model.jobs.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 27, weight: .light))
                                .foregroundStyle(.cyan.opacity(0.45))
                            Text("转换结果会出现在这里")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            Text("GIF 保存在原视频所在文件夹")
                                .font(.caption).foregroundStyle(.white.opacity(0.35))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(model.jobs) { job in jobRow(job) }
                            }.padding(10)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 155)

                Text("© 2026 YCCCC")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.28))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(26)
        }
        .frame(minWidth: 720, minHeight: 740)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { model.add(urls) }
        }
    }

    private var header: some View {
        HStack(spacing: 15) {
            Image(systemName: "film.stack.fill")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(LinearGradient(colors: [.cyan, Color(red: 0.18, green: 0.43, blue: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("视频转 GIF")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("清晰度与文件大小，由你掌控")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
            Label("本机处理", systemImage: "lock.shield")
                .font(.caption.weight(.medium))
                .foregroundStyle(.cyan.opacity(0.85))
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(.cyan.opacity(0.1), in: Capsule())
        }
    }

    private var settingsPanel: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("画质")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text("默认 1440px、25 帧/秒；可选择原尺寸")
                        .font(.caption).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Picker("画质", selection: $model.quality) {
                    Text("高清流畅 · 1440px / 25帧").tag(0)
                    Text("原尺寸 · 高效调色 / 大文件").tag(1)
                    Text("极致原画 · 原尺寸 / 超大文件").tag(2)
                    Text("高质量 · 1080px / 24帧").tag(3)
                    Text("均衡 · 720px / 15帧").tag(4)
                    Text("小文件 · 480px / 10帧").tag(5)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 300)
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("转换性能")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text("默认多核并行、保留细腻色彩；极速模式进一步缩短等待")
                        .font(.caption).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Picker("转换性能", selection: $model.speedMode) {
                    Text("高速保真 · 多核并行").tag(0)
                    Text("极速优先 · 色彩略有取舍").tag(1)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 240)
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GIF 播放倍速")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text("默认与原视频同倍速")
                        .font(.caption).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Picker("播放倍速", selection: $model.playbackSpeed) {
                    Text("0.5× · 慢放").tag(0.5)
                    Text("0.75×").tag(0.75)
                    Text("1× · 原速").tag(1.0)
                    Text("1.25×").tag(1.25)
                    Text("1.5×").tag(1.5)
                    Text("2× · 快放").tag(2.0)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 180)
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("文件大小上限")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(model.limitEnabled ? "自动寻找上限内的最佳画质" : "关闭时不限制输出大小")
                        .font(.caption).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Toggle("限制文件大小", isOn: $model.limitEnabled)
                    .labelsHidden().toggleStyle(.switch)
                TextField("10", value: $model.maxSizeMB, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 58)
                    .disabled(!model.limitEnabled)
                Text("MB")
                    .foregroundStyle(.white.opacity(model.limitEnabled ? 0.82 : 0.35))
            }
        }
        .padding(17)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 17))
    }

    private var dropZone: some View {
        Button { showingPicker = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 31, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                Text("把视频拖到这里")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("或点击选择文件 · 支持 MP4、MOV、MKV · 添加后点击开始转换")
                    .font(.caption).foregroundStyle(.white.opacity(0.48))
            }
            .foregroundStyle(model.isDragging ? .black : .cyan)
            .frame(maxWidth: .infinity).frame(height: 136)
            .background(model.isDragging ? Color.cyan : Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.cyan.opacity(model.isDragging ? 1 : 0.36), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])))
        }
        .buttonStyle(.plain)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDragging) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { model.add([url]) }
                }
            }
            return true
        }
    }

    private var startBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.pendingCount == 0 ? "添加视频后开始转换" : "已添加 \(model.pendingCount) 个待转换视频")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("可先调整画质、播放倍速和文件大小")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
            Button { model.startPending() } label: {
                Label("开始转换", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 142, height: 42)
                    .foregroundStyle(model.pendingCount > 0 ? Color.black : Color.white.opacity(0.42))
                    .background(model.pendingCount > 0 ? Color.cyan : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(model.pendingCount == 0)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 17))
    }

    private func playGIF(_ output: URL) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            NSWorkspace.shared.open(output)
            return
        }
        NSWorkspace.shared.open([output], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { NSWorkspace.shared.open(output) }
        }
    }

    private func jobRow(_ job: ConversionJob) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: job.status == .done ? "checkmark.circle.fill" : job.status == .failed ? "exclamationmark.circle.fill" : "film")
                .font(.system(size: 22))
                .foregroundStyle(job.status == .done ? .green : job.status == .failed ? .orange : .cyan)
                .frame(width: 27)
            VStack(alignment: .leading, spacing: 7) {
                Text(job.input.lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if job.status == .converting {
                    ProgressView(value: job.progress)
                        .tint(.cyan)
                    Text("\(job.stage) · \(Int(job.progress * 100))%")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                } else if job.status == .waiting {
                    Text("待转换 · 点击「开始转换」").font(.caption).foregroundStyle(.white.opacity(0.55))
                } else if job.status == .done, let output = job.output {
                    if job.sizeBytes > 0 {
                        Text(String(format: "%.2f MB · %@", Double(job.sizeBytes) / 1_000_000, job.stage))
                            .font(.caption).foregroundStyle(.green.opacity(0.8))
                    }
                    Text(output.path)
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2).textSelection(.enabled)
                    Text("请在 Safari 播放；系统「预览」只显示静态帧")
                        .font(.caption2).foregroundStyle(.white.opacity(0.42))
                } else {
                    Text(job.error)
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let output = job.output {
                VStack(alignment: .trailing, spacing: 7) {
                    Button("在 Safari 播放") { playGIF(output) }
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.cyan)
            } else if job.status == .failed {
                Button("打开原文件夹") { NSWorkspace.shared.open(job.input.deletingLastPathComponent()) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.cyan)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

@main
private struct GIFDropletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("视频转 GIF") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
