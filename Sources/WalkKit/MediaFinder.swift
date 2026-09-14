import Foundation

/// Everything in a folder that a proof sheet can show: the video files
/// `ClipFinder` already finds, plus the still formats.
///
/// WHY IT WRAPS `ClipFinder` INSTEAD OF LISTING EXTENSIONS AGAIN. The video
/// extension set is declared exactly once, in `ClipFinder.videoExtensions`, and
/// #507 is the reason: the app held a private copy of that set, so the app and
/// the library disagreed about what a video was and the contract could not say
/// which was right. A second set here would be the same defect with the same
/// shape. This adds the still formats and defers every video question.
public enum MediaFinder: Sendable {

    public enum Kind: String, Sendable {
        case clip
        case still
    }

    /// Still formats a proof sheet will decode.
    ///
    /// Deliberately the same conservative rule as `ClipFinder.videoExtensions`:
    /// a file Walk cannot open is worse than a file Walk declines to guess at.
    /// `heic` and `heif` are both listed because cameras write both spellings;
    /// `tif` and `tiff` likewise.
    public static let stillExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "dng", "png", "tif", "tiff",
    ]

    /// Extensions found alongside this material that are DELIBERATELY not shown,
    /// with the reason, so a skipped file is readable as a decision.
    ///
    /// `.LRF` is DJI's low-resolution proxy: the same footage as the `.MP4`
    /// beside it, at a fraction of the resolution. Showing both would double
    /// every DJI row with a worse copy of itself. MEASURED in the operator's own
    /// folder 2026-09-12: three `.LRF` files totalling 795 MB, each a duplicate
    /// of an `.MP4` already in the sheet.
    public static let knownIgnored: [String: String] = [
        "lrf": "DJI low-resolution proxy of the .MP4 beside it — the same clip at lower resolution, so showing it would duplicate the row",
        "srt": "DJI telemetry sidecar — read as evidence onto the clip's row rather than shown as an item of its own",
        "wav": "audio; Walk never reads audio (see video.audio in walk_contract)",
    ]

    public struct Item: Sendable {
        public let url: URL
        public let kind: Kind
        public let bytes: Int64
    }

    public struct Found: Sendable {
        public let items: [Item]
        public let directoriesSearched: [URL]
        /// Files that were not media, each with the reason it was passed over.
        public let skipped: [(url: URL, reason: String)]

        public var clips: [Item] { items.filter { $0.kind == .clip } }
        public var stills: [Item] { items.filter { $0.kind == .still } }
        public var foundNothing: Bool { items.isEmpty }

        public var verdict: String {
            if items.isEmpty {
                if directoriesSearched.isEmpty {
                    return "nothing to sheet — nothing given was a video or a still"
                }
                return "nothing to sheet — \(directoriesSearched.count) folder\(directoriesSearched.count == 1 ? "" : "s") searched, "
                    + (skipped.isEmpty ? "no files in them at all"
                       : "\(skipped.count) file\(skipped.count == 1 ? "" : "s") found and none of them media")
            }
            var s = "\(clips.count) clip\(clips.count == 1 ? "" : "s") and \(stills.count) still\(stills.count == 1 ? "" : "s")"
            if !skipped.isEmpty { s += ", \(skipped.count) file\(skipped.count == 1 ? "" : "s") skipped" }
            return s
        }
    }

    public static func find(_ inputs: [URL],
                            options: ClipFinder.Options = ClipFinder.Options()) -> Found {
        let fm = FileManager.default
        var items = [Item]()
        var searched = [URL]()
        var skipped = [(url: URL, reason: String)]()
        var seen = Set<String>()

        func size(_ url: URL) -> Int64 {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        }

        func consider(_ url: URL) {
            let standard = url.standardizedFileURL
            guard seen.insert(standard.path).inserted else { return }
            let ext = standard.pathExtension.lowercased()
            if ClipFinder.videoExtensions.contains(ext) {
                items.append(Item(url: standard, kind: .clip, bytes: size(standard)))
            } else if stillExtensions.contains(ext) {
                items.append(Item(url: standard, kind: .still, bytes: size(standard)))
            } else if let why = knownIgnored[ext] {
                skipped.append((standard, why))
            } else {
                skipped.append((standard, ext.isEmpty
                                ? "no extension, so Walk will not guess at the format"
                                : "'.\(ext)' is neither a video nor a still format Walk decodes"))
            }
        }

        for input in inputs {
            let url = input.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                skipped.append((url, "no file at this path"))
                continue
            }
            if isDirectory.boolValue {
                searched.append(url)
                if options.recursive {
                    let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    while let item = e?.nextObject() as? URL {
                        if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                        consider(item)
                    }
                } else {
                    let listed = (try? fm.contentsOfDirectory(at: url,
                                                              includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                              options: [.skipsHiddenFiles])) ?? []
                    for item in listed {
                        if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                        consider(item)
                    }
                }
            } else {
                consider(url)
            }
        }

        // Clips first, then stills, each in the finder's own natural order — the
        // same `localizedStandardCompare` ClipFinder sorts by, so DJI_..._0002
        // follows DJI_..._0001 rather than DJI_..._0010.
        items.sort { a, b in
            if a.kind != b.kind { return a.kind == .clip }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        skipped.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        if let cap = options.maximumClips, items.count > cap { items = Array(items.prefix(cap)) }
        return Found(items: items, directoriesSearched: searched, skipped: skipped)
    }

    public static func find(_ paths: [String],
                            options: ClipFinder.Options = ClipFinder.Options()) -> Found {
        find(paths.map { URL(fileURLWithPath: $0) }, options: options)
    }
}
