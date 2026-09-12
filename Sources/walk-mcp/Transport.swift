import Foundation

/// Serializes every write to stdout.
///
/// The stdio binding is explicit: "The server MUST NOT write anything to its
/// stdout that is not a valid MCP message", and messages are newline-delimited.
/// Two tasks printing at once interleave bytes and produce two unparseable
/// lines, so all output goes through one actor. `stderr` is the only place this
/// process is allowed to be chatty — the binding says a client "SHOULD NOT
/// assume stderr output indicates error conditions".
actor Wire {
    private let out: FileHandle
    private let logging: Bool
    /// Every message, as it goes past, when WALK_MCP_LOG names a file. This is
    /// how the era question gets ANSWERED rather than assumed: the log is what
    /// the host actually sent.
    private let traceURL: URL?

    init(out: FileHandle = .standardOutput,
         logging: Bool = ProcessInfo.processInfo.environment["WALK_MCP_VERBOSE"] != nil,
         traceURL: URL? = ProcessInfo.processInfo.environment["WALK_MCP_LOG"]
            .map { URL(fileURLWithPath: $0) }) {
        self.out = out
        self.logging = logging
        self.traceURL = traceURL
    }

    func send(_ message: JSON) {
        guard var data = try? message.line() else {
            note("REFUSING to send a message that would not encode")
            return
        }
        data.append(0x0A)
        out.write(data)
        trace(direction: "<<", data: data)
    }

    /// Diagnostics. stderr only.
    nonisolated func note(_ s: String) {
        FileHandle.standardError.write(("walk-mcp: " + s + "\n").data(using: .utf8)!)
    }

    nonisolated func verbose(_ s: String) {
        guard ProcessInfo.processInfo.environment["WALK_MCP_VERBOSE"] != nil else { return }
        note(s)
    }

    nonisolated func trace(direction: String, data: Data) {
        guard let traceURL else { return }
        var line = Data(direction.utf8); line.append(0x20)
        line.append(data)
        if line.last != 0x0A { line.append(0x0A) }
        if let h = try? FileHandle(forWritingTo: traceURL) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: traceURL)
        }
    }
}

/// stdin, one JSON-RPC message per line.
///
/// A dedicated thread does the blocking read and hands lines to the async world
/// through an `AsyncStream`. The alternative — reading inside the async loop —
/// blocks a cooperative-pool thread for the life of the process, which is the
/// documented way to deadlock structured concurrency.
enum Stdin {
    static func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) {
                    if line.isEmpty { continue }
                    continuation.yield(line)
                }
                // EOF on stdin is the primary graceful-shutdown signal and the
                // only portable one; the binding says servers SHOULD exit
                // promptly on it.
                continuation.finish()
            }
            thread.name = "walk-mcp.stdin"
            thread.stackSize = 1 << 20
            thread.start()
        }
    }
}
