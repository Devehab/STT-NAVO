import Foundation

/// Where to cut long audio so that no word is split between two pieces.
///
/// A cut is only made inside a real pause. Around the target point the audio is measured in
/// 10 ms frames. A frame is silent when it sits well below the speech around it: the threshold
/// follows the background level over time (the quietest 50 ms within 1.5 s either side), so a
/// quiet room, a noisy call and a fan that speeds up all work. Runs of silent frames are pauses.
/// A pause of at least 300 ms is a gap between phrases or a breath, never the closure inside a
/// word (Arabic geminate stops can hold 200 ms), so those are preferred; among them the longest
/// and cleanest wins, with a small preference for being close to the target. The cut goes inside
/// the pause, as near the target as the pause allows while keeping silence on both sides. Only
/// when the whole search range has no such pause does it fall back to shorter pauses, then to
/// the quietest 100 ms.
///
/// The engine uses the same method (engine/navo_engine/splitting.py) to fit each piece into a
/// model's input. Keep the two in step.
enum SmartCut {
    static let sampleRate = 16_000
    static let frame = 160 // 10 ms
    static let context = 3 * 16_000 // measured before the search range, for the background level
    static let lookahead = 16_000 // measured after it, so a pause at its end gets its true length
    static let pauseTiers: [Double] = [0.30, 0.15]
    static let margin = 0.15 // seconds of silence kept on each side of a cut when the pause allows
    static let alwaysSilentDB = -65.0
    static let silentPieceDB = -55.0 // loudest 100 ms below this: nothing to transcribe
    static let floorSmooth = 2 // frames on each side averaged before taking the floor
    static let floorReach = 150 // frames on each side searched for the floor

    /// Search range for a piece of about `targetSeconds`: 10 seconds either way, less for short pieces.
    static func radius(forTarget targetSeconds: Double) -> Int {
        Int(min(10, targetSeconds / 3) * Double(sampleRate))
    }

    /// Sample index in lo...hi where `samples` should be cut, as close to `target` as a pause allows.
    static func findCut(in samples: [Float], lo: Int, hi: Int, target: Int) -> Int {
        let total = samples.count
        let lo = max(0, min(lo, total))
        let hi = max(lo, min(hi, total))
        let target = min(max(target, lo), hi)
        guard hi - lo >= 2 * frame else { return target }

        let start = max(0, lo - context)
        let end = min(total, hi + lookahead)
        let levels = smooth(frameLevels(samples, from: start, to: end))
        guard !levels.isEmpty else { return target }
        let delta = contrast(levels)
        let floor = localFloor(levels)
        let count = levels.count
        var silent = [Bool](repeating: false, count: count)
        // 1 for a frame at the background level, 0 at the threshold: a real pause is nearly all 1s.
        var purity = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let threshold = floor[i] + delta
            silent[i] = levels[i] < threshold || levels[i] < alwaysSilentDB
            purity[i] = min(max((threshold - levels[i]) / delta, 0), 1)
        }

        struct Run {
            let seconds: Double
            let cut: Int
            let score: Double
        }
        let radius = Double(max(target - lo, hi - target, 1))
        let keepLimit = Int(margin * Double(sampleRate))
        var runs: [Run] = []
        var index = 0
        while index < count {
            guard silent[index] else {
                index += 1
                continue
            }
            let first = index
            while index < count && silent[index] {
                index += 1
            }
            let runStart = start + first * frame
            let runEnd = start + index * frame
            if runEnd <= lo || runStart >= hi { continue }
            let seconds = Double(runEnd - runStart) / Double(sampleRate)
            let keep = min((runEnd - runStart) / 2, keepLimit)
            var cut = min(max(target, runStart + keep), runEnd - keep)
            cut = min(max(cut, lo), hi)
            var clean = 0.0
            for i in first..<index {
                clean += purity[i]
            }
            clean /= Double(index - first)
            let score = min(seconds, 1.5) * (0.5 + 0.5 * clean) - 0.5 * Double(abs(cut - target)) / radius
            runs.append(Run(seconds: seconds, cut: cut, score: score))
        }

        for shortest in pauseTiers {
            var best: Run?
            for run in runs where run.seconds >= shortest {
                if best == nil || run.score > best!.score {
                    best = run
                }
            }
            if let best { return best.cut }
        }
        return quietestPoint(levels, start: start, lo: lo, hi: hi, target: target)
    }

    /// True when not even 100 ms of the audio is loud enough to hold speech.
    static func isSilent(_ samples: [Float]) -> Bool {
        let levels = frameLevels(samples, from: 0, to: samples.count)
        guard !levels.isEmpty else { return true }
        let power = levels.map { pow(10, $0 / 10) }
        let window = min(10, power.count)
        var loudest = 0.0
        for position in 0...(power.count - window) {
            var sum = 0.0
            for i in 0..<window {
                sum += power[position + i]
            }
            loudest = max(loudest, sum / Double(window))
        }
        return 10 * log10(loudest + 1e-10) < silentPieceDB
    }

    // MARK: Measuring

    /// Level of each 10 ms frame between `start` and `end` in dB (full scale 0 dB), DC offset removed.
    static func frameLevels(_ samples: [Float], from start: Int, to end: Int) -> [Double] {
        let count = max(0, (end - start) / frame)
        guard count > 0 else { return [] }
        var levels = [Double](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buffer in
            for f in 0..<count {
                let base = start + f * frame
                var sum = 0.0
                for i in 0..<frame {
                    sum += Double(buffer[base + i])
                }
                let mean = sum / Double(frame)
                var power = 0.0
                for i in 0..<frame {
                    let value = Double(buffer[base + i]) - mean
                    power += value * value
                }
                levels[f] = 10 * log10(power / Double(frame) + 1e-10)
            }
        }
        return levels
    }

    /// Median of 3: a single loud frame (a click) does not break a pause, a single quiet one does not make one.
    static func smooth(_ levels: [Double]) -> [Double] {
        guard levels.count >= 3 else { return levels }
        var smoothed = levels
        for i in 0..<levels.count {
            let a = levels[max(i - 1, 0)]
            let b = levels[i]
            let c = levels[min(i + 1, levels.count - 1)]
            smoothed[i] = max(min(a, b), min(max(a, b), c))
        }
        return smoothed
    }

    /// How far a frame must sit below the speech around it to count as silent, in dB.
    static func contrast(_ levels: [Double]) -> Double {
        let sorted = levels.sorted()
        let spread = percentile(sorted, 95) - percentile(sorted, 10)
        return min(max(0.25 * spread, 3), 15)
    }

    /// Background level around each frame: the quietest 50 ms within 1.5 s either side.
    static func localFloor(_ levels: [Double]) -> [Double] {
        let count = levels.count
        let width = 2 * floorSmooth + 1
        var averaged = [Double](repeating: 0, count: count)
        for i in 0..<count {
            var sum = 0.0
            for j in (i - floorSmooth)...(i + floorSmooth) {
                sum += levels[min(max(j, 0), count - 1)]
            }
            averaged[i] = sum / Double(width)
        }
        var floor = [Double](repeating: 0, count: count)
        for i in 0..<count {
            var lowest = Double.greatestFiniteMagnitude
            for j in max(0, i - floorReach)...min(count - 1, i + floorReach) {
                lowest = min(lowest, averaged[j])
            }
            floor[i] = lowest
        }
        return floor
    }

    /// Linear interpolation between the closest ranks, as numpy does by default.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = p / 100 * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// Middle of the quietest 100 ms between lo and hi; near-ties go to the one closest to target.
    static func quietestPoint(_ levels: [Double], start: Int, lo: Int, hi: Int, target: Int) -> Int {
        let window = 10
        let first = max(0, (lo - start) / frame)
        let last = min(levels.count, (hi - start) / frame)
        guard last - first >= window else { return target }
        var averages: [Double] = []
        averages.reserveCapacity(last - first - window + 1)
        for position in 0...(last - first - window) {
            var sum = 0.0
            for i in 0..<window {
                sum += levels[first + position + i]
            }
            averages.append(sum / Double(window))
        }
        let best = averages.min() ?? 0
        var chosen = target
        var distance = Int.max
        for (position, value) in averages.enumerated() where value <= best + 1 {
            let center = start + (first + position + window / 2) * frame
            if abs(center - target) < distance {
                distance = abs(center - target)
                chosen = center
            }
        }
        return chosen
    }
}
