import Foundation

/// The sidecar `.SRT` a DJI aircraft writes next to a clip, read as a
/// DISTRIBUTION over the whole file.
///
/// WHY A DISTRIBUTION AND NOT A READING. The obvious implementation reads the
/// first subtitle block and reports `iso: 100, shutter: 1/240`. On this material
/// that answer is wrong often enough to be useless: the aircraft is still
/// settling when frame 1 is written — it is climbing, the gimbal is levelling,
/// and auto-exposure has not converged. MEASURED 2026-09-12 on
/// `DJI_20260913024928_0001_D.SRT`, 10,782 samples: the modal shutter is
/// 1/10000 with 6,268 samples and the second mode is 1/8000 with 2,636, but the
/// file opens somewhere else entirely. A single-sample reading would have
/// reported a number that describes 1/10782nd of the clip.
///
/// So every field is summarized across every sample, and frame 1's value is
/// carried separately as `first` — reported, never used, so that a reader can
/// see for themselves how far the opening sample sits from the body of the clip.
///
/// This type MEASURES. It does not judge, and `ShutterRule` below is a
/// measurement against a named convention rather than a verdict: #513 puts
/// judgment in the criteria file and nowhere else.
public struct DroneTelemetry: Sendable {

    /// One numeric field summarized over every sample in the file.
    public struct Distribution: Sendable {
        public let samples: Int
        public let minimum: Double
        public let maximum: Double
        public let median: Double
        /// The most frequent value, and what share of the file sits on it. A
        /// mode holding 58% of a clip says something a mean cannot.
        public let mode: Double
        public let modeShare: Double
        /// Every distinct value with its count, most frequent first. Capped by
        /// the caller when serialized; kept whole here.
        public let distinct: [(value: Double, count: Int)]
        /// THE FIRST SAMPLE IN THE FILE, carried so it can be compared against
        /// the body of the clip — never so it can stand in for it.
        public let first: Double
        /// True when the file holds exactly one value for this field.
        public var constant: Bool { distinct.count == 1 }

        /// How far the opening sample sits from the median, in stops. Zero when
        /// the field never changed. Undefined (nil) for fields where a ratio is
        /// meaningless, which is why it is computed only where it is asked for.
        public var firstIsStopsFromMedian: Double? {
            guard first > 0, median > 0 else { return nil }
            return log2(first / median)
        }

        init?(_ values: [Double]) {
            guard let head = values.first, !values.isEmpty else { return nil }
            let sorted = values.sorted()
            var counts = [Double: Int]()
            for v in values { counts[v, default: 0] += 1 }
            let ranked = counts.sorted { a, b in
                a.value != b.value ? a.value > b.value : a.key < b.key
            }
            self.samples = values.count
            self.minimum = sorted.first!
            self.maximum = sorted.last!
            self.median = sorted.count % 2 == 1
                ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            self.mode = ranked[0].key
            self.modeShare = Double(ranked[0].value) / Double(values.count)
            self.distinct = ranked.map { (value: $0.key, count: $0.value) }
            self.first = head
        }
    }

    /// The 180-degree shutter convention, MEASURED against this clip's own
    /// frame rate. It is a comparison to a named standard, not a judgment about
    /// the footage: a deliberately fast shutter is a choice, and Walk does not
    /// own the question of whether it was the right one.
    ///
    /// The convention: a shutter of one over twice the frame rate gives a
    /// 180-degree shutter angle, the motion blur cinema has looked like since
    /// mechanical shutters. At 47.952 fps that is 1/95.9.
    public struct ShutterRule: Sendable {
        public let fps: Double
        /// 2 x fps — the denominator a 180-degree shutter would use.
        public let oneEightyDenominator: Double
        public let medianDenominator: Double
        /// log2(median / oneEighty). Positive means FASTER than the convention
        /// (less blur); negative means slower. One unit is one stop.
        public let stopsFromOneEighty: Double
        /// Half a stop either side, which is the working tolerance a shutter
        /// dial's detents allow. Stated as a field so the number is readable
        /// rather than buried in a comparison.
        public let toleranceStops: Double
        /// Share of the file's samples that sit inside the tolerance.
        public let shareWithinTolerance: Double
        public var withinTolerance: Bool { abs(stopsFromOneEighty) <= toleranceStops }
        /// Shutter angle implied by the median shutter, in degrees.
        /// 360 * fps / denominator. 180 is the convention; 1/10000 at 48 fps is
        /// 1.7 degrees.
        public var impliedShutterAngle: Double {
            medianDenominator > 0 ? 360.0 * fps / medianDenominator : .nan
        }

        public var note: String {
            let d = String(format: "1/%.0f", medianDenominator)
            let want = String(format: "1/%.0f", oneEightyDenominator)
            if withinTolerance {
                return "median shutter \(d) is within \(String(format: "%.2f", toleranceStops)) stop of the 180-degree value \(want) at \(String(format: "%.3f", fps)) fps"
            }
            return String(format: "median shutter %@ is %+.1f stops from the 180-degree value %@ at %.3f fps — an implied shutter angle of %.1f degrees against 180. MEASURED, not judged: a fast shutter is a choice and Walk does not rule on it.",
                          d, stopsFromOneEighty, want, fps, impliedShutterAngle)
        }

        init(fps: Double, denominators: [Double], toleranceStops: Double = 0.5) {
            let oneEighty = 2.0 * fps
            let sorted = denominators.sorted()
            let median = sorted.isEmpty ? .nan
                : (sorted.count % 2 == 1 ? sorted[sorted.count / 2]
                   : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2)
            self.fps = fps
            self.oneEightyDenominator = oneEighty
            self.medianDenominator = median
            self.stopsFromOneEighty = (median > 0 && oneEighty > 0) ? log2(median / oneEighty) : .nan
            self.toleranceStops = toleranceStops
            let inside = denominators.filter {
                $0 > 0 && oneEighty > 0 && abs(log2($0 / oneEighty)) <= toleranceStops
            }
            self.shareWithinTolerance = denominators.isEmpty
                ? 0 : Double(inside.count) / Double(denominators.count)
        }
    }

    public let source: URL
    /// Subtitle blocks that carried at least one recognized field.
    public let sampleCount: Int
    public let iso: Distribution?
    /// The DENOMINATOR of the shutter speed: 1/240 is carried as 240. Kept that
    /// way because the arithmetic a reader wants — stops, shutter angle — is on
    /// the denominator, and 1/240 as 0.004166 is a number nobody recognizes.
    public let shutterDenominator: Distribution?
    public let fNumber: Distribution?
    public let exposureValue: Distribution?
    public let focalLength: Distribution?
    public let relativeAltitude: Distribution?
    public let colorMode: String?
    /// Fields that appeared in the file and are not summarized above, so a
    /// reader can see that this parser saw them and chose not to model them.
    public let unmodeledKeys: [String]

    /// Every key this parser recognizes, so an absence is readable as an
    /// absence rather than as a parser that quietly missed something.
    public static let modeledKeys = ["iso", "shutter", "fnum", "ev", "focal_len",
                                     "rel_alt", "color_md"]

    public func shutterRule(fps: Double) -> ShutterRule? {
        guard let s = shutterDenominator, fps > 0 else { return nil }
        // Every sample, not the summary: the share inside tolerance is only
        // meaningful over the whole file.
        var all = [Double]()
        for (value, count) in s.distinct { all.append(contentsOf: Array(repeating: value, count: count)) }
        return ShutterRule(fps: fps, denominators: all)
    }

    /// The sidecar next to a clip, if one is there. DJI writes `NAME.SRT`
    /// alongside `NAME.MP4`; the lowercase spelling is checked too because a
    /// copy through a case-insensitive volume can change it.
    public static func sidecar(for clip: URL) -> URL? {
        let fm = FileManager.default
        for ext in ["SRT", "srt"] {
            let candidate = clip.deletingPathExtension().appendingPathExtension(ext)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Read and summarize a `.SRT`. Returns nil when the file cannot be read or
    /// holds no recognized field — an unreadable sidecar is an absence to
    /// report, not an error to abort a sheet over.
    public static func read(_ url: URL) -> DroneTelemetry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // DJI writes UTF-8; fall back to Latin-1 rather than lose the whole file
        // to one stray byte.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let text else { return nil }
        return parse(text, source: url)
    }

    /// PUBLIC so the parser can be tested against a fixture string with no file
    /// on disk — the known-answer material lives on an external volume and CI
    /// never sees it.
    public static func parse(_ text: String, source: URL) -> DroneTelemetry? {
        var iso = [Double](), shutter = [Double](), fnum = [Double]()
        var ev = [Double](), focal = [Double](), relAlt = [Double]()
        var colorMode: String? = nil
        var seenKeys = Set<String>()
        var samples = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains("[") else { continue }
            var got = false
            for (key, value) in fields(in: line) {
                seenKeys.insert(key)
                switch key {
                case "iso":       if let v = Double(value) { iso.append(v); got = true }
                case "shutter":   if let v = shutterDenominator(value) { shutter.append(v); got = true }
                case "fnum":      if let v = Double(value) { fnum.append(v); got = true }
                case "ev":        if let v = Double(value) { ev.append(v); got = true }
                case "focal_len": if let v = Double(value) { focal.append(v); got = true }
                case "rel_alt":   if let v = Double(value) { relAlt.append(v); got = true }
                case "color_md":  if colorMode == nil { colorMode = value }; got = true
                default: break
                }
            }
            if got { samples += 1 }
        }

        guard samples > 0 else { return nil }
        let unmodeled = seenKeys.subtracting(modeledKeys).sorted()
        return DroneTelemetry(
            source: source, sampleCount: samples,
            iso: Distribution(iso),
            shutterDenominator: Distribution(shutter),
            fNumber: Distribution(fnum),
            exposureValue: Distribution(ev),
            focalLength: Distribution(focal),
            relativeAltitude: Distribution(relAlt),
            colorMode: colorMode,
            unmodeledKeys: unmodeled)
    }

    /// `1/240.0` -> 240. Also accepts a bare `240`, and a genuine fraction
    /// below 1 such as `0.5` (a half-second exposure) as its reciprocal, so the
    /// field always means the same thing.
    ///
    /// The bare-number case is not hypothetical tolerance: DJI firmware has
    /// written both spellings, and a parser that silently returned nil for one
    /// of them would report "no shutter data" on a file full of it.
    static func shutterDenominator(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("1/") { return Double(s.dropFirst(2)) }
        guard let v = Double(s), v > 0 else { return nil }
        return v >= 1 ? v : 1.0 / v
    }

    /// Pull `name: value` pairs out of the bracketed run at the end of a DJI
    /// subtitle block.
    ///
    /// ONE BRACKET CAN HOLD TWO FIELDS and that is the reason this is a scanner
    /// rather than a split on `]`: DJI writes
    /// `[rel_alt: 1.600 abs_alt: 611.723]`, two keys inside one pair of
    /// brackets. Splitting on brackets gives `rel_alt` the value
    /// `1.600 abs_alt: 611.723`, which parses as nil and reads as missing data.
    static func fields<S: StringProtocol>(in line: S) -> [(String, String)] {
        var out = [(String, String)]()
        var tokens = [Substring]()
        // Strip the HTML wrapper DJI puts around the block before tokenizing;
        // `<font size="28">` would otherwise tokenize as junk.
        var stripped = ""
        var inTag = false
        for ch in line {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { stripped.append(ch) }
        }
        for piece in stripped.split(whereSeparator: { $0 == "[" || $0 == "]" }) {
            tokens.append(contentsOf: piece.split(whereSeparator: { $0 == " " || $0 == "\r" || $0 == "\t" }))
        }
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.hasSuffix(":"), i + 1 < tokens.count {
                let key = String(t.dropLast()).lowercased()
                var value = String(tokens[i + 1])
                if value.hasSuffix(",") { value.removeLast() }
                out.append((key, value))
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }
}
