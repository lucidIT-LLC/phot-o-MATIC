import Foundation

/// Finds the video files in what someone handed you — a file, a folder, or a
/// mixture of both.
///
/// WHY THIS IS IN THE LIBRARY AND NOT IN A FRONT DOOR. Decision #507, measured
/// from the operator's own screenshot: he dropped a folder of GoPro footage into
/// Walk.app and it walked eight clips, GX010035 through GX010042. It could do
/// that because `ProofSheetModel.open(_:)` held its own `contentsOfDirectory`
/// call and its own private `videoExtensions` set. So the APP walked folders and
/// the LIBRARY did not declare that it could — `ingest.dump` sat in
/// `Walk.notImplemented` the entire time.
///
/// That is contract drift inside the version contract, which is the one thing
/// the contract exists to catch. The resolution is not to edit the list until it
/// agrees with the app: it is to put the behavior where the tests are, declare
/// it under a name narrow enough to be true (`ingest.folderScan`), and leave
/// `ingest.dump` absent because the thing #496 asked for — ranking a dump by
/// interest — is still not built. Enumerating is solved. Sorting is not.
public enum ClipFinder: Sendable {

    /// Extensions treated as video. Deliberately conservative: a file Walk
    /// cannot open is worse than a file Walk declines to guess at.
    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mts", "m2ts", "avi", "mpg", "mpeg",
    ]

    public struct Options: Sendable {
        /// Descend into subdirectories. Off by default: "walk this folder"
        /// means this folder, and a recursive default is how a scan quietly
        /// becomes a hundred times longer than the person asking expected.
        public var recursive: Bool
        /// Hard ceiling on how many clips come back. `nil` is no ceiling.
        public var maximumClips: Int?
        public init(recursive: Bool = false, maximumClips: Int? = nil) {
            self.recursive = recursive
            self.maximumClips = maximumClips
        }
    }

    public struct Found: Sendable {
        public let clips: [URL]
        /// Directories that were opened, so a caller can say where it looked.
        public let directoriesSearched: [URL]
        /// Files that were passed in or found and were NOT video by extension.
        public let skipped: [URL]
        /// True when directories were searched and nothing video came back.
        /// An empty folder is an ANSWER, and saying so is the same discipline
        /// as `EventDetector.Result.foundNothing`.
        public var foundNothing: Bool { clips.isEmpty }

        public var verdict: String {
            if !clips.isEmpty {
                return "\(clips.count) clip\(clips.count == 1 ? "" : "s") to scan"
                    + (skipped.isEmpty ? "" : ", \(skipped.count) non-video file\(skipped.count == 1 ? "" : "s") skipped")
            }
            if directoriesSearched.isEmpty {
                return "nothing to scan — nothing given was a video file"
            }
            return "nothing to scan — \(directoriesSearched.count) folder\(directoriesSearched.count == 1 ? "" : "s") searched, "
                + (skipped.isEmpty ? "no files in them at all"
                                   : "\(skipped.count) file\(skipped.count == 1 ? "" : "s") found and none of them video")
        }
    }

    /// Resolve inputs to a sorted, de-duplicated list of video files.
    public static func find(_ inputs: [URL], options: Options = Options()) -> Found {
        let fm = FileManager.default
        var clips = [URL]()
        var searched = [URL]()
        var skipped = [URL]()
        var seen = Set<String>()

        func consider(_ url: URL) {
            let standard = url.standardizedFileURL
            guard seen.insert(standard.path).inserted else { return }
            if videoExtensions.contains(standard.pathExtension.lowercased()) {
                clips.append(standard)
            } else {
                skipped.append(standard)
            }
        }

        for input in inputs {
            let url = input.standardizedFileURL
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard exists else { skipped.append(url); continue }

            if isDirectory.boolValue {
                searched.append(url)
                if options.recursive {
                    let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    while let item = e?.nextObject() as? URL {
                        if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                        consider(item)
                    }
                } else {
                    let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles])) ?? []
                    for item in items {
                        if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                        consider(item)
                    }
                }
            } else {
                consider(url)
            }
        }

        clips.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        skipped.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if let cap = options.maximumClips, clips.count > cap { clips = Array(clips.prefix(cap)) }
        return Found(clips: clips, directoriesSearched: searched, skipped: skipped)
    }

    public static func find(_ paths: [String], options: Options = Options()) -> Found {
        find(paths.map { URL(fileURLWithPath: $0) }, options: options)
    }
}
