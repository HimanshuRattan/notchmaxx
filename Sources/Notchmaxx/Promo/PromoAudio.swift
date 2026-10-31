import AVFoundation

/// The promo soundtrack, synthesized so there is nothing to license: a 120 BPM backing track
/// that follows the video's sections, plus interface sounds placed on the video's cues.
enum PromoAudio {
    enum Cue {
        case click(Double)
        case ting(Double)
        case whoosh(Double, gain: Float)
        case pop(Double)
    }

    static let sampleRate = 48_000.0
    static let beat = 0.5

    static func write(duration: Double, cues: [Cue], to url: URL) throws {
        let count = Int(duration * sampleRate)
        var music = Bus(count: count)
        var send = Bus(count: count)
        Music.render(into: &music, send: &send)

        var sfx = Bus(count: count)
        for cue in cues {
            switch cue {
            case .click(let t): Sounds.click(at: t, into: &sfx)
            case .ting(let t): Sounds.ting(at: t, into: &sfx, send: &send)
            case .whoosh(let t, let gain): Sounds.whoosh(at: t, gain: gain, into: &sfx)
            case .pop(let t): Sounds.pop(at: t, into: &sfx, send: &send)
            }
        }
        let wet = Reverb.process(send)

        var out = Bus(count: count)
        for i in 0..<count {
            out.left[i] = music.left[i] * 0.5 + sfx.left[i] + wet.left[i] * 0.55
            out.right[i] = music.right[i] * 0.5 + sfx.right[i] + wet.right[i] * 0.55
        }
        master(&out)
        try encode(out, to: url)
    }

    /// Soft clip, normalize, and fade the edges.
    private static func master(_ bus: inout Bus) {
        var peak: Float = 0
        for i in 0..<bus.count {
            bus.left[i] = tanhf(bus.left[i] * 1.2)
            bus.right[i] = tanhf(bus.right[i] * 1.2)
            peak = max(peak, abs(bus.left[i]), abs(bus.right[i]))
        }
        let gain = peak > 0 ? 0.9 / peak : 1
        let fadeIn = Int(0.02 * sampleRate), fadeOut = Int(0.6 * sampleRate)
        for i in 0..<bus.count {
            var g = gain
            if i < fadeIn { g *= Float(i) / Float(fadeIn) }
            if i > bus.count - fadeOut { g *= Float(bus.count - i) / Float(fadeOut) }
            bus.left[i] *= g
            bus.right[i] *= g
        }
    }

    private static func encode(_ bus: Bus, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let chunk = 16_384
        var offset = 0
        while offset < bus.count {
            let frames = min(chunk, bus.count - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                buffer.floatChannelData![0][i] = bus.left[offset + i]
                buffer.floatChannelData![1][i] = bus.right[offset + i]
            }
            try file.write(from: buffer)
            offset += frames
        }
    }
}

fileprivate struct Bus {
    var left: [Float]
    var right: [Float]
    var count: Int { left.count }

    init(count: Int) {
        left = Array(repeating: 0, count: count)
        right = Array(repeating: 0, count: count)
    }

    /// Adds `length` seconds of a mono voice at `time`, panned from -1 (left) to 1 (right).
    mutating func add(at time: Double, length: Double, gain: Float, pan: Float = 0, _ voice: (Double, Int) -> Float) {
        let start = Int(time * PromoAudio.sampleRate)
        let frames = Int(length * PromoAudio.sampleRate)
        let l = gain * min(1, 1 - pan), r = gain * min(1, 1 + pan)
        for n in 0..<frames {
            let i = start + n
            guard i >= 0 else { continue }
            guard i < count else { break }
            let v = voice(Double(n) / PromoAudio.sampleRate, n)
            left[i] += v * l
            right[i] += v * r
        }
    }
}

/// One-pole low-pass, enough for synth tone shaping.
fileprivate struct OnePole {
    var y: Float = 0
    mutating func low(_ x: Float, cutoff: Double) -> Float {
        let a = Float(1 - exp(-2 * .pi * cutoff / PromoAudio.sampleRate))
        y += a * (x - y)
        return y
    }
}

/// Deterministic noise, so every render sounds the same.
fileprivate struct Noise {
    var state: UInt32 = 0x9E37_79B9
    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Float(state) / Float(UInt32.max) * 2 - 1
    }
}

private func midi(_ note: Int) -> Double { 440 * pow(2, Double(note - 69) / 12) }
private func saw(_ phase: Double) -> Float { Float(2 * (phase - floor(phase)) - 1) }

// MARK: - Music

/// Sections line up with the video: an intro under the title, the beat drops when the desktop
/// appears at 4s, drums fall away for the reset at 16s, return at 20s, and a final chord lands
/// on the end card at 28s.
private enum Music {
    static let chords = [[53, 57, 60, 64], [55, 59, 62, 69], [57, 60, 64, 67], [52, 55, 59, 62]]
    static let roots = [41, 43, 45, 40]
    static let bar = 4 * PromoAudio.beat
    static let step = PromoAudio.beat / 4

    static func drums(_ bar: Int) -> Bool { (2...7).contains(bar) || (10...13).contains(bar) }

    static func render(into bus: inout Bus, send: inout Bus) {
        // Tonal parts go on their own bus so they can duck under the kick.
        var tonal = Bus(count: bus.count)
        pad(into: &tonal)
        for b in 0..<14 {
            let t0 = Double(b) * bar
            let chord = chords[b % 4]
            if b <= 1 || b >= 8 { arp(chord, at: t0, gain: b >= 10 ? 0.035 : 0.06, into: &tonal, send: &send) }
            if drums(b) {
                for beatIndex in 0..<4 {
                    kick(at: t0 + Double(beatIndex) * PromoAudio.beat, into: &bus)
                }
                clap(at: t0 + PromoAudio.beat, into: &bus, send: &send)
                clap(at: t0 + 3 * PromoAudio.beat, into: &bus, send: &send)
                for s in 0..<16 {
                    let t = t0 + Double(s) * step
                    if s % 4 == 2 { hat(at: t, gain: 0.16, into: &bus) }
                    else if b >= 10 && s % 2 == 1 { hat(at: t, gain: 0.06, into: &bus) }
                    if [2, 6, 10, 14].contains(s) { bassNote(roots[b % 4], at: t, into: &tonal) }
                    if [0, 3, 6, 10, 12].contains(s) { pluck(chord, at: t, pan: s % 2 == 0 ? -0.35 : 0.35, into: &tonal, send: &send) }
                }
            }
        }
        for t in [2.0, 18.0] { riser(endingAt: t + bar, into: &bus) }
        for t in [4.0, 20.0, 28.0] { crash(at: t, into: &bus) }
        // End card: one held chord with a kick under it.
        kick(at: 28, into: &bus)
        pluck(chords[0], at: 28, pan: 0, into: &tonal, send: &send)
        bassNote(roots[0], at: 28, length: 1.6, into: &tonal)

        for i in 0..<bus.count {
            let t = Double(i) / PromoAudio.sampleRate
            var gain: Float = 1
            if drums(Int(t / bar)) {
                let sinceKick = t.truncatingRemainder(dividingBy: PromoAudio.beat)
                gain = Float(1 - 0.5 * exp(-sinceKick / 0.1))
            }
            bus.left[i] += tonal.left[i] * gain
            bus.right[i] += tonal.right[i] * gain
        }
    }

    static func pad(into bus: inout Bus) {
        var padBus = Bus(count: bus.count)
        let bars = 15
        for b in 0..<bars {
            let t0 = Double(b) * bar
            let chord = b == 14 ? chords[0] : chords[b % 4]
            let length = b == 14 ? 4.4 : bar + 0.5
            for note in chord {
                for (detune, pan) in [(-0.09, Float(-0.7)), (0.0, Float(0)), (0.09, Float(0.7))] {
                    let f = midi(note) * pow(2, detune / 12)
                    padBus.add(at: t0, length: length, gain: 0.035, pan: pan) { t, _ in
                        let attack = min(t / 0.35, 1)
                        let release = t > length - 0.5 ? max((length - t) / 0.5, 0) : 1
                        return saw(f * t + detune * 3) * Float(attack * release)
                    }
                }
            }
        }
        var lpL = OnePole(), lpR = OnePole(), lpL2 = OnePole(), lpR2 = OnePole()
        for i in 0..<bus.count {
            let t = Double(i) / PromoAudio.sampleRate
            // Darker under the title and the reset, open when the beat plays.
            let open = (4..<16).contains(t) || (20..<28).contains(t)
            let cutoff = open ? 1700.0 : 1300.0
            bus.left[i] += lpL2.low(lpL.low(padBus.left[i], cutoff: cutoff), cutoff: cutoff)
            bus.right[i] += lpR2.low(lpR.low(padBus.right[i], cutoff: cutoff), cutoff: cutoff)
        }
    }

    static func arp(_ chord: [Int], at t0: Double, gain: Float, into bus: inout Bus, send: inout Bus) {
        let order = [0, 1, 2, 3, 2, 1, 2, 3]
        for s in 0..<16 {
            let note = chord[order[s % order.count]] + 24
            let f = midi(note)
            let pan: Float = s % 2 == 0 ? -0.3 : 0.3
            let voice: (Double, Int) -> Float = { t, _ in
                Float(sin(2 * .pi * f * t) + 0.25 * sin(4 * .pi * f * t)) * Float(exp(-t / 0.11))
            }
            bus.add(at: t0 + Double(s) * step, length: 0.5, gain: gain, pan: pan, voice)
            send.add(at: t0 + Double(s) * step, length: 0.5, gain: gain * 0.6, pan: pan, voice)
        }
    }

    static func kick(at time: Double, into bus: inout Bus) {
        var phase = 0.0
        var noise = Noise()
        bus.add(at: time, length: 0.42, gain: 0.62) { t, _ in
            let f = 46 + 120 * exp(-t / 0.032)
            phase += f / PromoAudio.sampleRate
            let body = sin(2 * .pi * phase) * exp(-t / 0.3)
            let click = t < 0.003 ? Double(noise.next()) * 0.4 : 0
            return Float(body + click)
        }
    }

    static func clap(at time: Double, into bus: inout Bus, send: inout Bus) {
        var noise = Noise(state: 0x1234_5678)
        var lp = OnePole(), hp = OnePole()
        let voice: (Double, Int) -> Float = { t, _ in
            let bursts = [0.0, 0.011, 0.022].map { t >= $0 ? exp(-(t - $0) / 0.008) : 0 }.reduce(0, +)
            let env = bursts * 0.5 + (t >= 0.022 ? exp(-(t - 0.022) / 0.12) : 0)
            let x = noise.next()
            let high = x - hp.low(x, cutoff: 900)
            return lp.low(high, cutoff: 5200) * Float(env)
        }
        var cached: [Float] = []
        bus.add(at: time, length: 0.4, gain: 0.5) { t, n in
            let v = voice(t, n)
            cached.append(v)
            return v
        }
        send.add(at: time, length: 0.4, gain: 0.25) { _, n in n < cached.count ? cached[n] : 0 }
    }

    static func hat(at time: Double, gain: Float, into bus: inout Bus) {
        var noise = Noise(state: UInt32(time * 1000) | 1)
        var hp = OnePole()
        bus.add(at: time, length: 0.08, gain: gain, pan: 0.25) { t, _ in
            let x = noise.next()
            return (x - hp.low(x, cutoff: 7000)) * Float(exp(-t / 0.022))
        }
    }

    static func bassNote(_ note: Int, at time: Double, length: Double = 0.24, into bus: inout Bus) {
        let f = midi(note)
        bus.add(at: time, length: length, gain: 0.42) { t, _ in
            let env = min(t / 0.004, 1) * exp(-t / (length * 1.1))
            let tone = sin(2 * .pi * f * t) + 0.35 * sin(4 * .pi * f * t) + 0.12 * sin(6 * .pi * f * t)
            return Float(tanh(tone * 1.4) * env)
        }
    }

    static func pluck(_ chord: [Int], at time: Double, pan: Float, into bus: inout Bus, send: inout Bus) {
        for note in chord {
            let f = midi(note + 12)
            var lp = OnePole()
            var cached: [Float] = []
            bus.add(at: time, length: 0.45, gain: 0.05, pan: pan) { t, _ in
                let cutoff = 500 + 5200 * exp(-t / 0.05)
                let x = (saw(f * t) + saw(f * 1.004 * t)) * 0.5
                let v = lp.low(x, cutoff: cutoff) * Float(exp(-t / 0.16))
                cached.append(v)
                return v
            }
            // A dotted-eighth echo, panned the other way.
            for (i, delay) in [0.375, 0.75].enumerated() {
                send.add(at: time + delay, length: 0.45, gain: 0.04 / Float(i + 1), pan: -pan) { _, n in
                    n < cached.count ? cached[n] : 0
                }
            }
        }
    }

    static func riser(endingAt end: Double, into bus: inout Bus) {
        var noise = Noise(state: 0xBEEF)
        var lp = OnePole()
        let length = 2.0
        bus.add(at: end - length, length: length, gain: 0.16) { t, _ in
            let u = t / length
            let cutoff = 300 * pow(30, u)
            return lp.low(noise.next(), cutoff: cutoff) * Float(u * u)
        }
    }

    static func crash(at time: Double, into bus: inout Bus) {
        var noise = Noise(state: 0xC0FFEE)
        var hp = OnePole()
        let voice: (Double, Int) -> Float = { t, _ in
            let x = noise.next()
            return (x - hp.low(x, cutoff: 5000)) * Float(exp(-t / 0.7))
        }
        bus.add(at: time, length: 2.2, gain: 0.1, voice)
    }
}

// MARK: - Interface sounds

private enum Sounds {
    /// A trackpad-style click: a tiny transient, a tick and a soft body.
    static func click(at time: Double, into bus: inout Bus) {
        var noise = Noise(state: 0xA11CE)
        var lp = OnePole()
        bus.add(at: time, length: 0.07, gain: 0.55) { t, _ in
            let x = noise.next()
            let transient = (x - lp.low(x, cutoff: 3000)) * Float(exp(-t / 0.0015))
            let tick = Float(sin(2 * .pi * 3100 * t) * exp(-t / 0.005)) * 0.45
            let body = Float(sin(2 * .pi * 170 * t) * exp(-t / 0.018)) * 0.6
            return transient + tick + body
        }
    }

    /// Two bell strikes a fifth apart, the second just behind the first.
    static func ting(at time: Double, into bus: inout Bus, send: inout Bus) {
        let partials: [(ratio: Double, amp: Double, decay: Double)] = [(1, 1, 1.5), (2.76, 0.22, 0.45), (5.4, 0.07, 0.18), (8.93, 0.025, 0.09)]
        for (offset, f0, gain) in [(0.0, 1318.5, Float(0.26)), (0.075, 1975.5, Float(0.22))] {
            let voice: (Double, Int) -> Float = { t, _ in
                var v = 0.0
                for p in partials { v += p.amp * sin(2 * .pi * f0 * p.ratio * t) * exp(-t / p.decay) }
                return Float(v * min(t / 0.002, 1))
            }
            bus.add(at: time + offset, length: 2.2, gain: gain, pan: offset == 0 ? -0.1 : 0.1, voice)
            send.add(at: time + offset, length: 2.2, gain: gain * 0.9, voice)
        }
    }

    /// Band-passed noise swept up and back down, panned across.
    static func whoosh(at time: Double, gain: Float, into bus: inout Bus) {
        var noise = Noise(state: UInt32(time * 100) | 7)
        var lp = OnePole(), hp = OnePole()
        let length = 0.55
        for side in [Float(-1), 1] {
            bus.add(at: time - 0.12, length: length, gain: gain * 0.32, pan: side * 0.6) { t, _ in
                let u = t / length
                let center = 350 * pow(14, sin(.pi * u))
                let x = noise.next()
                let band = lp.low(x, cutoff: center * 1.6) - hp.low(x, cutoff: center * 0.5)
                let sweep = side < 0 ? 1 - u : u
                return band * Float(pow(sin(.pi * u), 2) * (0.4 + 0.6 * sweep))
            }
        }
    }

    /// A short rising bubble for each account that connects.
    static func pop(at time: Double, into bus: inout Bus, send: inout Bus) {
        var phase = 0.0
        let voice: (Double, Int) -> Float = { t, _ in
            let f = 560 + 520 * min(t / 0.03, 1)
            phase += f / PromoAudio.sampleRate
            return Float(sin(2 * .pi * phase) * exp(-t / 0.045) * min(t / 0.002, 1))
        }
        var cached: [Float] = []
        bus.add(at: time, length: 0.25, gain: 0.55) { t, n in
            let v = voice(t, n)
            cached.append(v)
            return v
        }
        send.add(at: time, length: 0.25, gain: 0.15) { _, n in n < cached.count ? cached[n] : 0 }
    }
}

// MARK: - Reverb

/// A small Schroeder reverb: parallel damped combs into series all-passes, offset per side.
private enum Reverb {
    static func process(_ input: Bus) -> Bus {
        var out = Bus(count: input.count)
        out.left = channel(input.left, spread: 0)
        out.right = channel(input.right, spread: 23)
        return out
    }

    private static func channel(_ x: [Float], spread: Int) -> [Float] {
        let scale = PromoAudio.sampleRate / 44_100
        let combs = [1557, 1617, 1491, 1422, 1277, 1356].map { Int(Double($0 + spread) * scale) }
        var y = Array(repeating: Float(0), count: x.count)
        for length in combs {
            var buffer = Array(repeating: Float(0), count: length)
            var index = 0
            var damp: Float = 0
            for i in 0..<x.count {
                let out = buffer[index]
                damp = out * 0.6 + damp * 0.4
                buffer[index] = x[i] + damp * 0.82
                index = (index + 1) % length
                y[i] += out / Float(combs.count)
            }
        }
        for length in [556, 441, 341].map({ Int(Double($0 + spread) * scale) }) {
            var buffer = Array(repeating: Float(0), count: length)
            var index = 0
            for i in 0..<y.count {
                let delayed = buffer[index]
                let v = y[i] + delayed * 0.5
                buffer[index] = v
                y[i] = delayed - v * 0.5
                index = (index + 1) % length
            }
        }
        return y
    }
}
