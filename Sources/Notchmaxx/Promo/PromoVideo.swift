import AppKit
import AVFoundation
import SwiftUI

/// `Notchmaxx --video <file.mp4>` renders a 32-second promo frame by frame from the real panel
/// views, then muxes in the synthesized soundtrack. It shows `DemoData`, with the Claude 5-hour
/// meter driven by the timeline so it can fill, hit the limit and reset on cue.
/// `--video-stills <dir>` writes a handful of frames for a quick look.
@MainActor
enum PromoVideo {
    static let size = CGSize(width: 1920, height: 1080)
    static let fps = 60
    nonisolated static let duration = 32.0

    enum Failure: Error { case writer, render(Double), mux }

    static func render(store: UsageStore, to output: URL) async throws {
        let scene = PromoScene(store: store)
        let stem = output.deletingPathExtension().path
        let videoURL = URL(fileURLWithPath: stem + ".frames.mov")
        let audioURL = URL(fileURLWithPath: stem + ".audio.m4a")
        try PromoAudio.write(duration: duration + 0.5, cues: PromoScene.audioCues, to: audioURL)
        print("Soundtrack done")
        try await writeFrames(scene, to: videoURL)
        try await mux(video: videoURL, audio: audioURL, to: output)
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: audioURL)
        print("Wrote \(output.path)")
    }

    static func stills(store: UsageStore, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scene = PromoScene(store: store)
        for t in [1.6, 4.4, 5.8, 6.2, 8.0, 10.15, 12.6, 14.3, 15.3, 16.2, 16.7, 17.5, 20.3, 22.2, 23.4, 24.6, 26.8, 29.5] {
            guard let image = scene.image(at: t) else { continue }
            let url = dir.appendingPathComponent(String(format: "t%05.2f.png", t))
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
        print("Stills in \(dir.path)")
    }

    private static func writeFrames(_ scene: PromoScene, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 24_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.writer }
        writer.startSession(atSourceTime: .zero)

        let total = Int(duration * Double(fps))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for frame in 0..<total {
            let t = Double(frame) / Double(fps)
            guard let image = autoreleasepool(invoking: { scene.image(at: t) }) else { throw Failure.render(t) }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? Failure.writer }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.writer }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(image, in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
            if frame % (fps * 2) == 0 { print("Frame \(frame) of \(total)") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.writer }
    }

    /// Copies the encoded video and audio into one MP4 without re-encoding either.
    nonisolated private static func mux(video: URL, audio: URL, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        var readers: [AVAssetReader] = []
        var lanes: [MuxLane] = []
        for (url, type) in [(video, AVMediaType.video), (audio, AVMediaType.audio)] {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: type).first else { throw Failure.mux }
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = range
            let source = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(source)
            let input = AVAssetWriterInput(mediaType: type, outputSettings: nil,
                                           sourceFormatHint: try await track.load(.formatDescriptions).first)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            readers.append(reader)
            lanes.append(MuxLane(source: source, input: input))
        }
        guard readers.allSatisfy({ $0.startReading() }), writer.startWriting() else { throw writer.error ?? Failure.mux }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { group in
            for (index, lane) in lanes.enumerated() {
                group.addTask { await lane.run(on: DispatchQueue(label: "promo.mux.\(index)")) }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.mux }
    }
}

/// One track being copied. Each lane is only touched from its own queue, which is what makes
/// the unchecked conformance safe.
private final class MuxLane: @unchecked Sendable {
    let source: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput

    init(source: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
        self.source = source
        self.input = input
    }

    func run(on queue: DispatchQueue) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while self.input.isReadyForMoreMediaData {
                    guard let sample = self.source.copyNextSampleBuffer() else {
                        self.input.markAsFinished()
                        done.resume()
                        return
                    }
                    self.input.append(sample)
                }
            }
        }
    }
}

// MARK: - Timeline

/// Cue times in seconds. At 120 BPM a bar is 2 seconds, and the clicks and the reset land on
/// downbeats.
private enum T {
    static let desktopIn = 3.7
    static let pillStart = 4.3
    static let pillEnd = 5.9
    static let expand1 = 6.0
    static let click1 = 10.0
    static let fillStart = 11.2
    static let fillEnd = 14.0
    static let collapse1 = 15.1
    static let bannerIn = 16.0
    static let ting = 16.5
    static let bannerOut = 19.0
    static let expand2 = 20.0
    static let click2 = 22.0
    static let connect = 24.0
    static let firstCheck = 25.0
    static let end = 28.0
}

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
private func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
private func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp01(x), 3) }
private func easeInOut(_ x: Double) -> Double {
    let x = clamp01(x)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}
private func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }

/// The closed-form step response of a damped spring, matching SwiftUI's `spring(response:dampingFraction:)`.
private func spring(_ elapsed: Double, response: Double = 0.42, damping: Double = 0.82) -> Double {
    guard elapsed > 0 else { return 0 }
    let omega = 2 * .pi / response
    let root = sqrt(1 - damping * damping)
    let decay = exp(-damping * omega * elapsed)
    return 1 - decay * (cos(omega * root * elapsed) + damping / root * sin(omega * root * elapsed))
}

/// A quick rise and slower settle, used for click feedback.
private func bump(_ x: Double) -> Double {
    guard x > 0 else { return 0 }
    return (1 - exp(-x / 0.035)) * exp(-x / 0.2)
}

// MARK: - Scene

@MainActor
private final class PromoScene {
    enum Layer: Hashable { case collapsed, panel(NotchTab), banner }

    /// Which part of a layer to draw. A tab switch keeps the header solid and swaps only the
    /// content below it.
    enum Region { case all, header, body }

    struct Part {
        var layer: Layer
        var opacity: Double
        var scale: Double = 1
        var lift: Double = 0
        var region: Region = .all
    }

    struct Shell {
        var size: CGSize
        var top: CGFloat
        var bottom: CGFloat
        var parts: [Part]
    }

    /// Top band plus tab bar, in points.
    static let headerHeight: CGFloat = 76

    struct Caption {
        var title: String
        var sub: String
        var start: Double
        var end: Double
        var centered = false
    }

    static let audioCues: [PromoAudio.Cue] = [
        .whoosh(T.expand1, gain: 1), .click(T.click1), .whoosh(T.collapse1, gain: 0.5),
        .whoosh(T.bannerIn, gain: 0.6), .ting(T.ting), .whoosh(T.bannerOut, gain: 0.4),
        .whoosh(T.expand2, gain: 1), .click(T.click2), .whoosh(T.connect, gain: 0.9),
    ] + (0..<4).map { .pop(T.firstCheck + Double($0) * 0.5) }

    static let captions = [
        Caption(title: "Every account.", sub: "One glance.", start: 7.0, end: 9.7),
        Caption(title: "See the wall coming.", sub: "Pace checks say when you'll run out.", start: 10.9, end: 14.7),
        Caption(title: "Know as soon as it resets.", sub: "Then send the heavy tasks.", start: 16.9, end: 19.1, centered: true),
        Caption(title: "Spare resets?", sub: "Spend them before they expire.", start: 22.8, end: 24.0),
    ]

    /// Camera keyframes in screen points: time, focus point and zoom.
    static let camera: [(t: Double, x: Double, y: Double, s: Double)] = [
        (0, 756, 425, 1.27), (T.desktopIn, 756, 425, 1.27), (4.1, 756, 410, 1.32),
        (4.9, 756, 210, 2.65), (5.8, 756, 215, 2.6), (7.0, 547, 285, 1.9), (10.4, 547, 285, 1.9),
        (11.2, 566, 258, 2.1), (14.8, 566, 258, 2.1), (15.8, 756, 208, 2.6),
        (19.3, 756, 208, 2.6), (20.4, 547, 285, 1.9), (22.3, 547, 285, 1.9),
        (23.0, 600, 217, 2.5), (24.3, 600, 217, 2.62),
    ]

    static let cursor: [(t: Double, x: Double, y: Double)] = [
        (4.2, 1120, 640), (5.7, 800, 22), (6.6, 800, 22), (7.4, 760, 250), (9.0, 760, 250),
        (9.85, 700.5, 56), (10.5, 700.5, 56), (11.3, 790, 200), (14.3, 790, 200), (15.0, 1180, 560),
        (19.1, 1180, 560), (19.9, 800, 22), (20.6, 800, 22), (21.85, 811.5, 56), (22.4, 811.5, 56),
        (23.2, 900, 300),
    ]

    let store: UsageStore
    let base: [AccountSnapshot]
    let baseSessions: [LiveSession]
    let baseStats: TokenStats
    let notch = CGSize(width: 185, height: 32)
    let world = CGSize(width: 1512, height: 982)
    let wallpaper: CGImage?
    let tabModels: [NotchTab: NotchModel]
    let collapsedModel = NotchModel()
    let resetAlert: AlertItem
    var sizes: [Layer: CGSize] = [:]
    var checkProgress = 0.0

    init(store: UsageStore) {
        self.store = store
        base = store.accounts
        baseSessions = store.sessions
        baseStats = store.stats
        var models: [NotchTab: NotchModel] = [:]
        for tab in NotchTab.allCases {
            let model = NotchModel()
            model.tab = tab
            model.presentation = .expanded
            model.tabGlide = 0
            models[tab] = model
        }
        tabModels = models
        let claude = base.first { $0.provider == .claude }
        resetAlert = AlertItem(kind: .reset, provider: .claude, accountName: claude?.name ?? "Claude",
                               title: "5-hour limit reset", message: "Claude · \(claude?.name ?? "Claude") is clear again",
                               percent: 0, severity: .normal)
        let paper = ImageRenderer(content: Desktop().frame(width: world.width, height: world.height))
        paper.scale = 1.6
        wallpaper = paper.cgImage

        for model in [collapsedModel] + Array(models.values) { model.notchSize = notch }
        stage(at: 0)
        for layer in [Layer.collapsed, .banner] + NotchTab.allCases.map(Layer.panel) {
            let host = NSHostingView(rootView: layerView(layer).fixedSize().environment(\.colorScheme, .dark))
            sizes[layer] = host.fittingSize
        }
    }

    func image(at t: Double) -> CGImage? {
        stage(at: t)
        let renderer = ImageRenderer(content: frame(at: t).environment(\.colorScheme, .dark))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(PromoVideo.size)
        return renderer.cgImage
    }

    /// The staged Claude 5-hour meter: it climbs in the collapsed pill as the desktop appears,
    /// ticks up while the overview is open, races to the limit on the Claude tab, then resets.
    static func fill(at t: Double) -> Double {
        if t >= T.ting { return 0 }
        if t >= T.fillEnd { return 100 }
        if t >= T.fillStart { return lerp(46, 100, easeInOut(seg(t, T.fillStart, T.fillEnd))) }
        if t >= T.pillEnd { return lerp(38, 46, seg(t, T.pillEnd, T.fillStart)) }
        return 38 * easeInOut(seg(t, T.pillStart, T.pillEnd))
    }

    /// Tokens added on top of today's real totals, rising with the meter.
    static func extraTokens(at t: Double) -> Int {
        let millions = 4.2 * easeInOut(seg(t, T.pillStart, T.pillEnd)) + 1.6 * seg(t, T.pillEnd, T.fillStart)
            + 14.5 * easeInOut(seg(t, T.fillStart, T.fillEnd)) + 0.8 * seg(t, T.fillEnd, T.end)
        return Int(millions * 1_000_000)
    }

    /// Sets the staged meter, tokens, tab highlight and check for this instant.
    private func stage(at t: Double) {
        let fill = Self.fill(at: t)
        let cleared = t >= T.ting
        let extra = Self.extraTokens(at: t)
        let claudeSession = baseSessions.first { $0.provider == .claude && $0.isBusy }
        let claudeKey = claudeSession?.accountKey ?? base.first { $0.provider == .claude }?.key ?? "claude"
        var stats = baseStats
        stats.records.append(UsageRecord(day: TokenStats.dayKey(.now), provider: .claude, account: claudeKey,
                                         model: "promo", counts: TokenCounts(input: extra)))
        let sessions = baseSessions.map { session in
            var session = session
            if session.id == claudeSession?.id { session.tokens += extra }
            return session
        }
        store.stage(base.map { account in
            guard account.provider == .claude else { return account }
            var account = account
            account.windows = account.windows.map { window in
                guard window.id == "session" else { return window }
                var window = window
                window.usedPercent = fill
                window.resetsAt = cleared ? nil : Date().addingTimeInterval(6320)
                window.length = 5 * 3600
                return window
            }
            return account
        }, sessions: sessions, stats: stats)

        var glide = 0.0
        if t >= T.click1 { glide = spring(t - T.click1, response: 0.34, damping: 0.86) }
        if t >= T.expand2 { glide = 1 }
        if t >= T.click2 { glide = 1 + spring(t - T.click2, response: 0.34, damping: 0.86) }
        for model in tabModels.values { model.tabGlide = glide }
        checkProgress = seg(t, T.ting - 0.05, T.ting + 0.6)
    }

    // MARK: Frame

    @ViewBuilder
    private func frame(at t: Double) -> some View {
        let desktop = seg(t, T.desktopIn, T.desktopIn + 0.6) * (1 - seg(t, T.connect - 0.2, T.connect + 0.3))
        let connect = seg(t, T.connect - 0.1, T.connect + 0.4) * (1 - seg(t, T.end - 0.4, T.end))
        ZStack {
            Color.black
            if desktop > 0 {
                camera(at: t)
                    .opacity(desktop)
                    .blur(radius: (1 - desktop) * 18)
                ForEach(Array(Self.captions.enumerated()), id: \.offset) { _, caption in
                    if t > caption.start - 0.1 && t < caption.end + 0.1 { self.captionView(caption, at: t) }
                }
            }
            if connect > 0 {
                connectScene(at: t)
                    .opacity(connect)
                    .blur(radius: (1 - connect) * 14)
                    .scaleEffect(0.97 + 0.03 * connect)
            }
            if t < 4.2 { titleScene(at: t) }
            if t > T.end - 0.1 { endScene(at: t) }
        }
        .frame(width: PromoVideo.size.width, height: PromoVideo.size.height)
        .clipped()
    }

    private func camera(at t: Double) -> some View {
        let keys = Self.camera
        var cam = keys.last!
        for (a, b) in zip(keys, keys.dropFirst()) where t >= a.t && t < b.t {
            let u = easeInOut(seg(t, a.t, b.t))
            cam = (t, lerp(a.x, b.x, u), lerp(a.y, b.y, u), lerp(a.s, b.s, u))
        }
        let punch = bump(t - T.click1) + bump(t - T.click2)
        let s = cam.s * (1 + 0.045 * punch)
        let half = PromoVideo.size
        let fx = min(max(cam.x, half.width / 2 / s), world.width - half.width / 2 / s)
        let fy = max(cam.y, half.height / 2 / s)
        return worldView(at: t)
            .scaleEffect(s, anchor: .topLeading)
            .offset(x: half.width / 2 - fx * s, y: half.height / 2 - fy * s)
            .frame(width: half.width, height: half.height, alignment: .topLeading)
            .clipped()
    }

    private func worldView(at t: Double) -> some View {
        ZStack(alignment: .top) {
            if let wallpaper {
                Image(decorative: wallpaper, scale: 1.6).resizable().frame(width: world.width, height: world.height)
            }
            MenuBar(height: notch.height)
            shellView(shell(at: t))
            Color.clear
                .overlay(alignment: .topLeading) { chipGlow(at: t) }
                .overlay(alignment: .topLeading) { cursorView(at: t) }
        }
        .frame(width: world.width, height: world.height, alignment: .top)
    }

    // MARK: Notch shell

    private func shell(at t: Double) -> Shell {
        let steps: [(start: Double, from: Layer, to: Layer)] = [
            (T.expand1, .collapsed, .panel(.overview)),
            (T.click1, .panel(.overview), .panel(.claude)),
            (T.collapse1, .panel(.claude), .collapsed),
            (T.bannerIn, .collapsed, .banner),
            (T.bannerOut, .banner, .collapsed),
            (T.expand2, .collapsed, .panel(.claude)),
            (T.click2, .panel(.claude), .panel(.codex)),
        ]
        guard let step = steps.last(where: { t >= $0.start }) else {
            return Shell(size: sizes[.collapsed]!, top: 6, bottom: 11, parts: [Part(layer: .collapsed, opacity: 1)])
        }
        let e = t - step.start
        let p = spring(e)
        let a = sizes[step.from]!, b = sizes[step.to]!
        func radii(_ layer: Layer) -> (Double, Double) { layer == .collapsed ? (6, 11) : (14, 28) }
        let ra = radii(step.from), rb = radii(step.to), rp = clamp01(p)

        var parts: [Part]
        switch (step.from, step.to) {
        case (.panel, .panel):
            // Old content fades out before the new content rises in, so they never overlap.
            let rise = easeOut(seg(e, 0.1, 0.36))
            parts = [Part(layer: step.to, opacity: 1, region: .header),
                     Part(layer: step.from, opacity: 1 - seg(e, 0, 0.12), region: .body),
                     Part(layer: step.to, opacity: rise, lift: (1 - rise) * 10, region: .body)]
        case (_, .collapsed):
            parts = [Part(layer: step.from, opacity: 1 - seg(e, 0, 0.1)),
                     Part(layer: step.to, opacity: seg(e, 0.14, 0.3))]
        default:
            parts = [Part(layer: step.from, opacity: 1 - seg(e, 0, 0.1)),
                     Part(layer: step.to, opacity: seg(e, 0.08, 0.3), scale: 0.97 + 0.03 * easeOut(seg(e, 0.08, 0.4)))]
        }
        return Shell(
            size: CGSize(width: lerp(a.width, b.width, p), height: lerp(a.height, b.height, p)),
            top: lerp(ra.0, rb.0, rp), bottom: lerp(ra.1, rb.1, rp),
            parts: parts.filter { $0.opacity > 0.001 })
    }

    private func shellView(_ shell: Shell) -> some View {
        let lift = clamp01((shell.size.height - 40) / 60)
        return ZStack(alignment: .top) {
            NotchShape(topRadius: shell.top, bottomRadius: shell.bottom).fill(Color.black)
            ForEach(Array(shell.parts.enumerated()), id: \.offset) { _, part in
                self.layerView(part.layer)
                    .fixedSize()
                    .offset(y: part.lift)
                    .mask(alignment: .top) { self.regionMask(part.region) }
                    .scaleEffect(part.scale, anchor: .top)
                    .opacity(part.opacity)
            }
        }
        .frame(width: shell.size.width, height: shell.size.height, alignment: .top)
        .clipShape(NotchShape(topRadius: shell.top, bottomRadius: shell.bottom))
        .shadow(color: .black.opacity(0.55 * lift), radius: 24, y: 10)
    }

    @ViewBuilder
    private func regionMask(_ region: Region) -> some View {
        switch region {
        case .all: Rectangle()
        case .header: Rectangle().frame(height: Self.headerHeight)
        case .body: VStack(spacing: 0) { Color.clear.frame(height: Self.headerHeight); Rectangle() }
        }
    }

    @ViewBuilder
    private func layerView(_ layer: Layer) -> some View {
        switch layer {
        case .collapsed:
            CollapsedNotch(model: collapsedModel, store: store, showPill: true, inset: 6)
        case .panel(let tab):
            ExpandedPanel(model: tabModels[tab]!, store: store, actions: NotchActions(), inset: 14)
        case .banner:
            AlertBanner(alert: resetAlert, notch: notch, inset: 14, checkProgress: checkProgress)
        }
    }

    // MARK: Cursor and highlights

    private func cursorView(at t: Double) -> some View {
        let keys = Self.cursor
        var point = CGPoint(x: keys[0].x, y: keys[0].y)
        if let last = keys.last, t >= last.t { point = CGPoint(x: last.x, y: last.y) }
        for (a, b) in zip(keys, keys.dropFirst()) where t >= a.t && t < b.t {
            let u = easeInOut(seg(t, a.t, b.t))
            point = CGPoint(x: lerp(a.x, b.x, u), y: lerp(a.y, b.y, u))
        }
        let press = max(bump(t - T.click1), bump(t - T.click2))
        let ripples = [T.click1, T.click2].map { seg(t, $0, $0 + 0.55) }.filter { $0 > 0 && $0 < 1 }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(ripples.enumerated()), id: \.offset) { _, u in
                let r = 4 + 20 * easeOut(u)
                Circle()
                    .stroke(Color.white.opacity(0.85 * (1 - u)), lineWidth: 1.6 * (1 - u) + 0.4)
                    .frame(width: r * 2, height: r * 2)
                    .offset(x: -r, y: -r)
            }
            ZStack {
                Arrow().fill(Color.black)
                Arrow().stroke(Color.white, style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
            }
            .frame(width: 12, height: 19.5)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .scaleEffect(1 - 0.16 * press, anchor: .topLeading)
        }
        .offset(x: point.x, y: point.y)
        .opacity(seg(t, 4.2, 4.45))
    }

    /// A soft ring around the Codex manual-reset chip.
    private func chipGlow(at t: Double) -> some View {
        let on = seg(t, 22.8, 23.1) * (1 - seg(t, 23.9, 24.2))
        let breathe = 0.75 + 0.25 * sin((t - 22.8) * 2 * .pi / 1.1)
        return Capsule()
            .stroke(Theme.good.opacity(0.9 * on * breathe), lineWidth: 1.4)
            .shadow(color: Theme.good.opacity(0.8 * on), radius: 6)
            .frame(width: 244, height: 28)
            .offset(x: 534, y: 192)
    }

    // MARK: Captions and cards

    private func captionView(_ caption: Caption, at t: Double) -> some View {
        let first = easeOut(seg(t, caption.start, caption.start + 0.6))
        let second = easeOut(seg(t, caption.start + 0.18, caption.start + 0.78))
        let out = seg(t, caption.end - 0.4, caption.end)
        let presence = first * (1 - out)
        let text = VStack(alignment: caption.centered ? .center : .leading, spacing: 12) {
            Text(caption.title)
                .font(.system(size: 70, weight: .semibold))
                .tracking(-1.4)
                .foregroundStyle(.white)
                .opacity(first)
                .blur(radius: (1 - first) * 12)
                .offset(y: (1 - first) * 18)
            Text(caption.sub)
                .font(.system(size: 34, weight: .medium))
                .tracking(-0.4)
                .foregroundStyle(.white.opacity(0.62))
                .opacity(second)
                .blur(radius: (1 - second) * 10)
                .offset(y: (1 - second) * 14)
        }
        .multilineTextAlignment(caption.centered ? .center : .leading)
        .opacity(1 - out)
        .blur(radius: out * 10)

        return ZStack(alignment: caption.centered ? .center : .leading) {
            if caption.centered {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .opacity(presence)
                text.offset(y: 170)
            } else {
                LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.3), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.55, y: 0.5))
                    .opacity(presence)
                text.padding(.leading, 130).frame(maxWidth: 760, alignment: .leading)
            }
        }
        .frame(width: PromoVideo.size.width, height: PromoVideo.size.height, alignment: caption.centered ? .center : .leading)
    }

    private func words(_ text: String, size: CGFloat, weight: Font.Weight, color: Color, start: Double, at t: Double) -> some View {
        let parts = text.split(separator: " ").map(String.init)
        return HStack(spacing: size * 0.26) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, word in
                let p = easeOut(seg(t, start + Double(index) * 0.09, start + Double(index) * 0.09 + 0.55))
                Text(word)
                    .font(.system(size: size, weight: weight))
                    .tracking(-size * 0.018)
                    .foregroundStyle(color)
                    .opacity(p)
                    .blur(radius: (1 - p) * 14)
                    .offset(y: (1 - p) * size * 0.22)
            }
        }
    }

    private func titleScene(at t: Double) -> some View {
        let out = seg(t, 3.3, 3.9)
        return VStack(spacing: 22) {
            words("You're wasting tokens", size: 104, weight: .semibold, color: .white, start: 0.35, at: t)
            words("if you're not hitting your limits.", size: 50, weight: .medium, color: .white.opacity(0.55), start: 1.45, at: t)
        }
        .scaleEffect(1 + 0.04 * out)
        .opacity(1 - out)
        .blur(radius: out * 16)
    }

    private func connectScene(at t: Double) -> some View {
        let rows: [(Provider, String, String)] = base.map { account in
            let detail = [account.name == account.provider.name ? nil : account.name, account.plan]
                .compactMap { $0 }.joined(separator: " · ")
            return (account.provider, account.provider.name, detail)
        }
        return ZStack {
            if let wallpaper {
                Image(decorative: wallpaper, scale: 1.6).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: PromoVideo.size.width, height: PromoVideo.size.height).clipped()
            }
            Color.black.opacity(0.35)
            VStack(spacing: 44) {
                VStack(spacing: 12) {
                    words("Finds every account.", size: 66, weight: .semibold, color: .white, start: T.connect + 0.1, at: t)
                    words("Work and personal, side by side.", size: 32, weight: .medium, color: .white.opacity(0.62), start: T.connect + 0.35, at: t)
                }
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, 104) }
                        self.connectRow(row, index: index, at: t)
                    }
                }
                .padding(.vertical, 10)
                .frame(width: 860)
                .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.black.opacity(0.82)))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            }
        }
        .frame(width: PromoVideo.size.width, height: PromoVideo.size.height)
    }

    private func connectRow(_ row: (Provider, String, String), index: Int, at t: Double) -> some View {
        let appear = easeOut(seg(t, T.connect + 0.4 + 0.1 * Double(index), T.connect + 0.9 + 0.1 * Double(index)))
        let checkAt = T.firstCheck + 0.5 * Double(index)
        return HStack(spacing: 22) {
            ProviderGlyph(provider: row.0, size: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.1).font(.system(size: 27, weight: .semibold)).foregroundStyle(.white)
                Text(row.2).font(.system(size: 21)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            ZStack {
                if t < checkAt {
                    Circle()
                        .trim(from: 0.1, to: 0.78)
                        .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 26, height: 26)
                        .rotationEffect(.degrees(t * 420))
                } else {
                    CheckBadge(progress: seg(t, checkAt, checkAt + 0.5), size: 34)
                }
            }
            .frame(width: 40)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 20)
        .opacity(appear)
        .blur(radius: (1 - appear) * 6)
        .offset(y: (1 - appear) * 26)
    }

    private func endScene(at t: Double) -> some View {
        let fade = 1 - seg(t, 31.2, 32)
        return ZStack {
            Color.black
            VStack(spacing: 34) {
                HStack(spacing: 30) {
                    ForEach(Array(Provider.allCases.enumerated()), id: \.offset) { index, provider in
                        let p = spring(t - (T.end + 0.05 + 0.1 * Double(index)), response: 0.5, damping: 0.7)
                        ProviderGlyph(provider: provider, size: 88)
                            .scaleEffect(max(p, 0))
                            .opacity(clamp01(p * 2))
                    }
                }
                VStack(spacing: 16) {
                    words("Notchmaxx", size: 124, weight: .semibold, color: .white, start: T.end + 0.45, at: t)
                    words("Your limits, live in your notch.", size: 40, weight: .medium, color: .white.opacity(0.55), start: T.end + 0.85, at: t)
                }
            }
            .opacity(fade)
        }
        .opacity(seg(t, T.end - 0.1, T.end + 0.2))
    }
}

/// The macOS arrow pointer, tip at the top left.
private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(Double, Double)] = [(0, 0), (0, 0.85), (0.33, 0.66), (0.57, 0.985), (0.78, 0.93), (0.56, 0.61), (1, 0.61)]
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for (x, y) in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height))
        }
        path.closeSubpath()
        return path
    }
}
