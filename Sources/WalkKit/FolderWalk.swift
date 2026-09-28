import Foundation

/// The ONE directory traversal in Walk. `ClipFinder` and `MediaFinder` both
/// classify what this returns; neither lists a directory itself.
///
/// WHY IT EXISTS (task #1013, Smith's audit, measured). Two findings about the
/// same forty lines:
///
///   P1 — `ClipFinder.find` and `MediaFinder.find` each carried their own copy of
///        the walk: existence check, recursive enumerator or flat listing, skip
///        directories, de-duplicate. Two copies of a traversal is how the app
///        once walked folders the library did not declare (#507); the fix then
///        was to move the walk into ONE place, and it had quietly become two.
///
///   P2 — both copies read a directory as `(try? fm.contentsOfDirectory(...)) ?? []`
///        and ran the recursive enumerator with no `errorHandler`. A folder the
///        process may not read therefore came back as "searched, zero media" —
///        the same answer as an empty folder, with no reason. That is absence
///        indistinguishable from success, in the component whose whole verdict
///        is built to tell "nothing here" from "could not look".
///
/// So every failure to read is RECORDED with its reason, and the verdict of each
/// finder says so. An unreadable folder is not an empty one.
public enum FolderWalk: Sendable {

    /// A directory, or an entry under one, that could not be read.
    public struct Unreadable: Sendable, Equatable {
        public let url: URL
        public let reason: String
        public init(url: URL, reason: String) { self.url = url; self.reason = reason }
    }

    public struct Listing: Sendable {
        /// Regular files, standardized and de-duplicated, in discovery order.
        public let files: [URL]
        /// Inputs that do not exist at all.
        public let missing: [URL]
        /// Directories that were opened (or attempted), so a caller can say
        /// where it looked.
        public let directoriesSearched: [URL]
        /// Directories or entries that could not be read, each with the reason.
        public let unreadable: [Unreadable]
    }

    /// Walk the inputs. A file input is returned as-is; a directory input is
    /// listed (one level, or all levels when `recursive`), hidden files skipped.
    public static func list(_ inputs: [URL], recursive: Bool,
                            keys: [URLResourceKey] = []) -> Listing {
        let fm = FileManager.default
        let resourceKeys = Array(Set(keys + [.isDirectoryKey]))
        var files = [URL]()
        var missing = [URL]()
        var searched = [URL]()
        var unreadable = [Unreadable]()
        var seen = Set<String>()

        func add(_ url: URL) {
            let standard = url.standardizedFileURL
            guard seen.insert(standard.path).inserted else { return }
            files.append(standard)
        }

        func isDirectory(_ item: URL) -> Bool {
            do {
                return try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            } catch {
                // Could not even ask what it is. Recorded, not guessed at.
                unreadable.append(Unreadable(url: item.standardizedFileURL,
                                             reason: reason(for: error)))
                return true   // excluded from files either way
            }
        }

        for input in inputs {
            let url = input.standardizedFileURL
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &dir) else {
                missing.append(url)
                continue
            }
            guard dir.boolValue else { add(url); continue }

            searched.append(url)
            if recursive {
                // THE errorHandler IS THE P2 FIX FOR THE RECURSIVE PATH. Without
                // it the enumerator skips an unreadable subdirectory silently.
                // Returning true continues the walk past it, so one locked
                // folder does not end a scan of everything else.
                var enumerationErrors = [Unreadable]()
                let e = fm.enumerator(at: url, includingPropertiesForKeys: resourceKeys,
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                      errorHandler: { failed, error in
                                          enumerationErrors.append(Unreadable(
                                              url: failed.standardizedFileURL,
                                              reason: reason(for: error)))
                                          return true
                                      })
                if let e {
                    while let item = e.nextObject() as? URL {
                        if isDirectory(item) { continue }
                        add(item)
                    }
                } else {
                    enumerationErrors.append(Unreadable(url: url,
                        reason: "the system returned no enumerator for this folder"))
                }
                unreadable.append(contentsOf: enumerationErrors)
            } else {
                do {
                    let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys,
                                                           options: [.skipsHiddenFiles])
                    for item in items where !isDirectory(item) { add(item) }
                } catch {
                    unreadable.append(Unreadable(url: url, reason: reason(for: error)))
                }
            }
        }
        return Listing(files: files, missing: missing, directoriesSearched: searched,
                       unreadable: unreadable)
    }

    /// A reason a person can act on. Permission is named plainly because it is
    /// the common case on macOS (privacy-protected folders) and the fix is a
    /// setting, not a retry. Anything else carries the POSIX description when
    /// there is one, then the system's own description.
    public static func reason(for error: Error) -> String {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix: Int32? = {
            if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
            if let u = underlying, u.domain == NSPOSIXErrorDomain { return Int32(u.code) }
            return nil
        }()
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError
            || posix == EACCES || posix == EPERM {
            return "permission denied — this process may not read it (on macOS, check Privacy & Security > Files and Folders or Full Disk Access for the host app)"
        }
        if let p = posix { return String(cString: strerror(p)) }
        return ns.localizedDescription
    }
}
