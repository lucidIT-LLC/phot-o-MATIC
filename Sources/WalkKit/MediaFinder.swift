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
        /// Folders, or entries in them, that could not be read, with the reason
        /// (task #1013 P2). Not folded into `skipped`: "could not look" is a
        /// different answer from "looked, and it was not media".
        public let unreadable: [FolderWalk.Unreadable]

        public init(items: [Item], directoriesSearched: [URL],
                    skipped: [(url: URL, reason: String)],
                    unreadable: [FolderWalk.Unreadable] = []) {
            self.items = items
            self.directoriesSearched = directoriesSearched
            self.skipped = skipped
            self.unreadable = unreadable
        }

        public var clips: [Item] { items.filter { $0.kind == .clip } }
        public var stills: [Item] { items.filter { $0.kind == .still } }
        public var foundNothing: Bool { items.isEmpty }

        public var verdict: String {
            let unread = unreadable.isEmpty ? ""
                : "; \(unreadable.count) location\(unreadable.count == 1 ? "" : "s") could not be read — see unreadable for why"
            return baseVerdict + unread
        }

        private var baseVerdict: String {
            if items.isEmpty {
                if directoriesSearched.isEmpty {
                    return "nothing to sheet — nothing given was a video or a still"
                }
                return "nothing to sheet — \(directoriesSearched.count) folder\(directoriesSearched.count == 1 ? "" : "s") searched, "
                    + (skipped.isEmpty ? (unreadable.isEmpty ? "no files in them at all" : "nothing readable in them")
                       : "\(skipped.count) file\(skipped.count == 1 ? "" : "s") found and none of them media")
            }
            var s = "\(clips.count) clip\(clips.count == 1 ? "" : "s") and \(stills.count) still\(stills.count == 1 ? "" : "s")"
            if !skipped.isEmpty { s += ", \(skipped.count) file\(skipped.count == 1 ? "" : "s") skipped" }
            return s
        }
    }

    public static func find(_ inputs: [URL],
                            options: ClipFinder.Options = ClipFinder.Options()) -> Found {
        // The directory walk is `FolderWalk`'s, shared with `ClipFinder`, so the
        // two finders cannot drift apart on how a folder is read (task #1013 P1).
        let listing = FolderWalk.list(inputs, recursive: options.recursive, keys: [.fileSizeKey])
        var items = [Item]()
        var skipped = listing.missing.map { (url: $0, reason: "no file at this path") }

        func size(_ url: URL) -> Int64 {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        }

        for file in listing.files {
            let ext = file.pathExtension.lowercased()
            if ClipFinder.videoExtensions.contains(ext) {
                items.append(Item(url: file, kind: .clip, bytes: size(file)))
            } else if stillExtensions.contains(ext) {
                items.append(Item(url: file, kind: .still, bytes: size(file)))
            } else if let why = knownIgnored[ext] {
                skipped.append((file, why))
            } else {
                skipped.append((file, ext.isEmpty
                                ? "no extension, so Walk will not guess at the format"
                                : "'.\(ext)' is neither a video nor a still format Walk decodes"))
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
        return Found(items: items, directoriesSearched: listing.directoriesSearched,
                     skipped: skipped, unreadable: listing.unreadable)
    }

    public static func find(_ paths: [String],
                            options: ClipFinder.Options = ClipFinder.Options()) -> Found {
        find(paths.map { URL(fileURLWithPath: $0) }, options: options)
    }
}
