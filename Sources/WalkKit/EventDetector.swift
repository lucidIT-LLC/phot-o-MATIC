import Foundation

/// Turns a luminance time series into discrete candidate events.
///
/// THE LESSON THIS CLASS EXISTS TO ENCODE. Decision #495: a 640-wide `ffmpeg`
/// pass over clip 0012 reported four lightning strikes. A full-resolution Core
/// Image scan found six — frames 2334 and 2340 had been below a CONSTANT
/// threshold after the downscale, and full-resolution ffmpeg then confirmed both.
/// The tool was not wrong; the fixed threshold was. So the threshold here is
/// derived from the clip's own statistics.
///
/// AND THE HONEST LIMIT OF THAT, which matters just as much. A purely
/// statistical threshold can never report "nothing found": scale it to the
/// clip's own noise and a quiet clip still yields the same fraction of
/// outliers. So the threshold is `max(statistical, floor)` and BOTH halves are
/// load-bearing — the statistical half is what stops a downscale artifact from
/// hiding a real strike, and the floor is what lets an empty clip come back
/// empty. Neither alone is sufficient, and saying so is the point.
public struct EventDetector: Sendable {

    public struct Options: Sendable {
        /// Neighbours each side used for the local median baseline. Wide enough
        /// to ignore a single bright frame, narrow enough to track a moving
        /// exposure.
        public var window: Int
        /// Multiple of the robust (MAD-derived) sigma of the relative-rise
        /// distribution. 12 is a deliberately wide bar: on clip 0012 the
        /// distribution is so tight (sigma = 0.025%) that 12 sigma is only
        /// 0.30%, which is why the floor exists.
        public var sigmaMultiple: Double
        /// Absolute floor on relative rise. A whole-frame mean luminance rise
        /// below this is not reported however unusual it is for the clip.
        /// THIS IS THE CONSTANT, and it is named as one: it is what makes
        /// "nothing found" reachable, and it is also what would hide a real
        /// event on a clip whose strikes are fainter than 1%.
        public var minimumRelativeRise: Double
        /// Candidates within this many frames collapse to their peak, so one
        /// flash spanning two frames is one event.
        public var mergeWithin: Int

        public init(window: Int = 8, sigmaMultiple: Double = 12.0,
                    minimumRelativeRise: Double = 0.01, mergeWithin: Int = 2) {
            self.window = window; self.sigmaMultiple = sigmaMultiple
            self.minimumRelativeRise = minimumRelativeRise; self.mergeWithin = mergeWithin
        }
    }

    public struct Event: Sendable {
        public let index: Int
        public let time: Double
        public let value: Double
        /// Local median of the neighbours, excluding this frame.
        public let baseline: Double
        public var delta: Double { value - baseline }
        public var relativeRise: Double { baseline != 0 ? (value - baseline) / baseline : 0 }
        /// Rise in units of the clip's own robust sigma. Large numbers are
        /// normal here: a tripod shot's residual distribution is very tight.
        public let sigma: Double
        /// Frames merged into this one (1 when nothing merged).
        public let mergedFrames: Int
    }

    public struct Result: Sendable {
        public let events: [Event]
        public let framesConsidered: Int
        /// The threshold actually applied, as a relative rise.
        public let threshold: Double
        public let statisticalThreshold: Double
        public let floorThreshold: Double
        /// Which half bound. Reported so a reader can tell whether the answer
        /// came from the clip or from the constant.
        public let boundBy: BoundBy
        public let robustSigma: Double
        public let medianRelativeRise: Double
        public let candidatesBeforeMerge: Int
        /// True when the robust scale estimator collapsed to zero — more than
        /// half the frames sit exactly on their local median, so the clip
        /// supplies no measurable noise scale and the statistical half of the
        /// threshold carries no information.
        ///
        /// MEASURED on the six storm clips, 2026-09-12: this is TRUE for clips
        /// 0010 and 0011, and on the other four the statistical threshold came
        /// out at 0.096%, 0.105%, 0.189% and 0.301% — all below the 1% floor. On
        /// this material the statistical half never bound. It is a guard against
        /// the opposite failure, a clip noisier than the floor, and that case
        /// did not occur here, so it is UNEXERCISED on real footage.
        public let scaleCollapsed: Bool

        public enum BoundBy: String, Sendable { case statistics, floor }

        public var foundNothing: Bool { events.isEmpty }

        /// A sentence that is true in both directions. A detector that cannot
        /// say "nothing" is a detector that always agrees with you.
        public var verdict: String {
            if threshold <= 0 {
                return String(format: "cannot be determined — %d frames carry no measurable variation and the floor is %.4f%%, so every frame would qualify; refusing to report events",
                              framesConsidered, floorThreshold * 100)
            }
            if events.isEmpty {
                return String(format: "nothing found — %d frames considered, none rose %.3f%% above its local median (%@ bound the threshold)",
                              framesConsidered, threshold * 100, boundBy.rawValue)
            }
            return String(format: "%d candidate%@ over %d frames at a %.3f%% threshold (%@ bound)",
                          events.count, events.count == 1 ? "" : "s",
                          framesConsidered, threshold * 100, boundBy.rawValue)
        }
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    public func detect(_ series: LumaSeries) -> Result {
        detect(values: series.values, indices: series.indices,
               times: series.samples.map(\.time))
    }

    /// The whole detector on plain numbers, so it can be tested without a file.
    public func detect(values: [Double], indices: [Int]? = nil, times: [Double]? = nil) -> Result {
        let n = values.count
        let idx = indices ?? Array(0..<n)
        guard n > 2 else {
            return Result(events: [], framesConsidered: n, threshold: options.minimumRelativeRise,
                          statisticalThreshold: 0, floorThreshold: options.minimumRelativeRise,
                          boundBy: .floor, robustSigma: 0, medianRelativeRise: 0,
                          candidatesBeforeMerge: 0, scaleCollapsed: true)
        }

        // 1. Local median baseline, excluding the frame under test. Excluding it
        //    matters: include it and a single very bright frame drags its own
        //    baseline up and partly hides itself.
        var baselines = [Double](repeating: 0, count: n)
        var relative = [Double](repeating: 0, count: n)
        let w = max(1, options.window)
        for k in 0..<n {
            let lo = max(0, k - w), hi = min(n - 1, k + w)
            var neighbours = [Double]()
            neighbours.reserveCapacity(hi - lo)
            for j in lo...hi where j != k { neighbours.append(values[j]) }
            neighbours.sort()
            let median = neighbours.isEmpty ? values[k] : neighbours[neighbours.count / 2]
            baselines[k] = median
            relative[k] = median != 0 ? (values[k] - median) / median : 0
        }

        // 2. Robust scale of the relative-rise distribution. MAD, not standard
        //    deviation: the events themselves would inflate an SD and raise the
        //    bar that is supposed to catch them.
        let sortedRel = relative.sorted()
        let medianRel = sortedRel[sortedRel.count / 2]
        let deviations = relative.map { abs($0 - medianRel) }.sorted()
        let mad = deviations[deviations.count / 2]
        let robustSigma = 1.4826 * mad   // MAD -> sigma for a normal distribution

        let statistical = medianRel + options.sigmaMultiple * robustSigma
        let floorT = options.minimumRelativeRise
        let threshold = max(statistical, floorT)

        // 3. Candidates, then merge to peaks.
        // A threshold of zero or less would flag every frame at or above its own
        // local median — roughly half the clip. That is not a detection, it is
        // an inability to measure, and it is reported as one.
        var raw = [(Int, Int)]()   // (position, frame index)
        if threshold > 0 {
            for k in 0..<n where relative[k] >= threshold { raw.append((k, idx[k])) }
        }

        var events = [Event]()
        var group = [Int]()        // positions
        func flush() {
            guard let peak = group.max(by: { relative[$0] < relative[$1] }) else { return }
            events.append(Event(index: idx[peak],
                                time: times?[peak] ?? Double(idx[peak]),
                                value: values[peak], baseline: baselines[peak],
                                sigma: robustSigma > 0 ? relative[peak] / robustSigma : .infinity,
                                mergedFrames: group.count))
            group.removeAll()
        }
        for (pos, frame) in raw {
            if let lastPos = group.last, frame - idx[lastPos] <= options.mergeWithin {
                group.append(pos)
            } else { flush(); group = [pos] }
        }
        flush()

        return Result(events: events, framesConsidered: n, threshold: threshold,
                      statisticalThreshold: statistical, floorThreshold: floorT,
                      boundBy: statistical > floorT ? .statistics : .floor,
                      robustSigma: robustSigma, medianRelativeRise: medianRel,
                      candidatesBeforeMerge: raw.count,
                      scaleCollapsed: robustSigma == 0)
    }
}
