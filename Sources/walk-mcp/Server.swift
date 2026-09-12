import Foundation
import WalkKit

/// The MCP protocol surface. Dual-era, and that is a measured decision rather
/// than belt-and-braces.
///
/// THE SPEC MOVED. The current revision, `2026-07-28`, removed the `initialize`
/// handshake: every request now declares its own version in
/// `_meta["io.modelcontextprotocol/protocolVersion"]`, servers MUST implement
/// `server/discover`, and an unsupported version comes back as
/// `UnsupportedProtocolVersionError` (-32022). Revisions up to and including
/// `2025-11-25` are what that page calls LEGACY, and they handshake.
///
/// Walk cannot know which era the host it is registered with speaks, and
/// guessing is how you ship a front door that reports compliance it does not
/// have. The spec's own compatibility matrix says a DUAL-ERA server works with
/// both client eras, so this implements both: `server/discover` and per-request
/// `_meta` for modern clients, `initialize` for legacy ones. What the host
/// actually sent is recorded in `WALK_MCP_LOG`, so the answer is measured and
/// not inferred.
enum Protocols {
    /// Modern revisions, newest first.
    static let modern = ["2026-07-28"]
    /// Legacy, handshake-based revisions this server will answer, newest first.
    static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static var all: [String] { modern + legacy }

    static let metaVersionKey = "io.modelcontextprotocol/protocolVersion"
    static let metaServerInfoKey = "io.modelcontextprotocol/serverInfo"

    /// -32022, from the schema. Not a number picked to look plausible.
    static let unsupportedProtocolVersion = -32022
}

struct RPCError: Error {
    let code: Int
    let message: String
    let data: JSON?
    init(_ code: Int, _ message: String, data: JSON? = nil) {
        self.code = code; self.message = message; self.data = data
    }
    static func invalidParams(_ m: String) -> RPCError { RPCError(-32602, m) }
    static func methodNotFound(_ m: String) -> RPCError { RPCError(-32601, "Unknown method: \(m)") }
    static func internalError(_ m: String) -> RPCError { RPCError(-32603, m) }
}

let serverInfo: JSON = .object([
    "name": .string("walk"),
    "version": .string(Walk.version),
])

/// Read by a model before it picks a tool, so it says what the numbers mean and
/// where the edge of the detector is. #507 is the reason the "what a candidate
/// is" paragraph is here: the operator dropped in a folder of GoPro footage, got
/// 38 "candidates" on one clip, and the honest reading of those is brightness
/// changes.
///
/// 0.5.0 REWROTE THE FIRST PARAGRAPH BECAUSE IT SHIPPED THE OPPOSITE DOCTRINE.
/// It read, verbatim: "It never renders a keep/pitch verdict — sorting and
/// flagging is Walk's job, judgment is yours and the operator's." Decision #513
/// reverses that exactly: Walk's output is a COACHING VERDICT, not a measurement
/// readout. So this string — the one text a host reads BEFORE it chooses a tool,
/// served to every consumer on connect — was describing a product decision that
/// had been overturned, which is this factory's most-repeated defect class
/// sitting in the most-read sentence it owns. A consumer told "never renders a
/// verdict" does not ask for one, so the prose was not merely stale, it
/// suppressed the feature.
///
/// What it must NOT do in correcting that is claim the verdict works. It does
/// not yet: no criteria ship (#499, `coach.verdict` in `Walk.notImplemented`),
/// so every scan reports `coaching.available = false` with the reason. This text
/// says both halves — the doctrine and the current absence — because either one
/// alone is a lie of a different kind.
let serverInstructions = """
Walk is a COACHING tool for photographers, not a readout. Its output is a \
verdict in three bands, each carrying a reason and a lesson for next flight: \
SELLABLE AS SHOT (good, and why — the craft a buyer is paying for, not the \
number); HAS POTENTIAL, WITH THIS (the one specific change, then the question \
"where did you want to go?", which is required and not decoration); and NOT \
WORTH THE TROUBLE (why, plainly, so the tell is learned). The goal is sellable, \
professional output and better photographers.

THE VERDICT IS NOT AVAILABLE IN THIS BUILD AND EVERY RESULT SAYS SO. The bands \
are rendered from a criteria file that carries Pixel's judgment, and Walk ships \
none, so each scan returns `coaching.available: false` with the reason and the \
paths it looked in. Read that field rather than assuming: when a criteria set is \
installed the same scans come back banded, with the measurements as evidence \
underneath. Until then the honest answer to "is this frame any good" is that \
Walk measured it and cannot yet judge it — say that, and do not substitute a \
verdict of your own invention for the missing one.

The measurements are the EVIDENCE UNDER a verdict, available and not leading. \
They are good and they are not the answer: a frame that scores badly can be the \
photograph, and ranking by a number is how the first scan of the storm clip lost \
two real strikes.

Start with walk_contract to learn this build's version and exactly which \
capabilities are present and absent. Every absent capability carries a reason.

walk_scan_folder is the tool for "go walk this folder". walk_scan is one clip. \
Both return, per candidate frame: the frame index, timecode, seconds, the \
relative luminance rise over a local median baseline, that rise in units of the \
clip's own robust sigma, 10-bit Y-plane statistics, and Vision classifier \
confidences. Candidates also carry a `thumbnail` path — a written PNG you can \
read to SHOW the operator the frame rather than describe it.

WHAT A CANDIDATE IS, AND IS NOT. The detector is a whole-frame luminance-rise \
trigger with an image classifier attached. On storm footage a candidate is \
usually a lightning flash. On anything else a candidate is a brightness change \
— a cloud, a turn toward the sun, an exposure shift — and a high count means \
the light moved a lot, not that the clip is interesting. Read the `lightning` \
confidence and look at the thumbnail before telling the operator he has fifty \
moments. Luminance finds bright flashes; classification finds lightning; they \
are different measurements and Walk reports both separately on purpose.

"Nothing found" is a real answer and is reported as one, with the threshold \
that was applied and which half of it bound. So is "measured but not judged".
"""

/// Which era the client opened with, for diagnostics only. Never used to change
/// an answer — the protocol is answered from what each request carries.
actor EraNote {
    private var recorded: String?
    func record(_ era: String, _ wire: Wire) {
        guard recorded != era else { return }
        recorded = era
        wire.note("client era: \(era)")
    }
}

struct Server {
    let wire: Wire
    let era = EraNote()

    /// Handle one incoming line. Returns nothing; every reply goes out the wire.
    func handle(_ line: String) async {
        wire.trace(direction: ">>", data: Data(line.utf8))
        let message: JSON
        do { message = try JSON.parse(Data(line.utf8)) }
        catch {
            // A parse error has no id to correlate against, so it goes out with
            // a null id per JSON-RPC rather than being swallowed.
            await wire.send(.object([
                "jsonrpc": .string("2.0"), "id": .null,
                "error": .object(["code": .int(-32700), "message": .string("Parse error")]),
            ]))
            return
        }
        guard let obj = message.objectValue else { return }
        let method = obj["method"]?.stringValue
        let id = obj["id"]

        // A notification has no id. Nothing may be sent in reply to one.
        guard let id, id != .null else {
            if let method { await handleNotification(method, params: obj["params"]) }
            return
        }
        guard let method else {
            await reply(id: id, error: RPCError(-32600, "Invalid Request — no method"))
            return
        }

        let params = obj["params"] ?? .object([:])

        // Modern version gate. Only applies when the request actually declares a
        // version; a legacy request carries none and is served as legacy.
        if let declared = params["_meta"]?[Protocols.metaVersionKey]?.stringValue {
            await era.record("modern (declared \(declared))", wire)
            guard Protocols.all.contains(declared) else {
                await reply(id: id, error: RPCError(
                    Protocols.unsupportedProtocolVersion, "Unsupported protocol version",
                    data: .object([
                        "supported": .array(Protocols.all.map { .string($0) }),
                        "requested": .string(declared),
                    ])))
                return
            }
        }

        do {
            // nil means SEND NOTHING. The only case is a cancelled request: the
            // stdio binding says a server "MUST NOT send any further messages
            // for it", so a cancelled tool call is silent rather than answered
            // with an error the client has no request left to match it to.
            if let result = try await dispatch(method: method, params: params, id: id) {
                await reply(id: id, result: result)
            } else {
                wire.verbose("no reply sent for cancelled request \(id)")
            }
        } catch let e as RPCError {
            await reply(id: id, error: e)
        } catch {
            await reply(id: id, error: .internalError("\(error)"))
        }
    }

    private func handleNotification(_ method: String, params: JSON?) async {
        switch method {
        case "notifications/initialized", "initialized":
            wire.verbose("client finished the legacy handshake")
        case "notifications/cancelled":
            if let raw = params?["requestId"] {
                await Running.shared.cancel(raw)
                wire.verbose("cancelled \(raw)")
            }
        default:
            wire.verbose("ignoring notification \(method)")
        }
    }

    private func dispatch(method: String, params: JSON, id: JSON) async throws -> JSON? {
        switch method {

        // MARK: modern
        case "server/discover":
            return .object([
                "resultType": .string("complete"),
                "supportedVersions": .array(Protocols.all.map { .string($0) }),
                "capabilities": .object(["tools": .object([:])]),
                "instructions": .string(serverInstructions),
                "_meta": .object([Protocols.metaServerInfoKey: serverInfo]),
            ])

        // MARK: legacy
        case "initialize":
            // Echo back the client's own version when this server speaks it, so
            // a legacy client gets the revision it asked for; otherwise name the
            // newest legacy revision, because a legacy client has no way to
            // fall forward and this string may be its only diagnostic.
            let asked = params["protocolVersion"]?.stringValue
            let agreed = (asked.flatMap { Protocols.all.contains($0) ? $0 : nil })
                ?? Protocols.legacy[0]
            await era.record("legacy (initialize, asked \(asked ?? "nothing"), agreed \(agreed))", wire)
            return .object([
                "protocolVersion": .string(agreed),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": serverInfo,
                "instructions": .string(serverInstructions),
            ])

        case "ping":
            return .object([:])

        // MARK: tools
        case "tools/list":
            return .object(["tools": .array(Tools.all.map(\.definition))])

        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                throw RPCError.invalidParams("tools/call requires a tool name")
            }
            guard let tool = Tools.all.first(where: { $0.name == name }) else {
                throw RPCError(-32602, "Unknown tool: \(name)")
            }
            let arguments = params["arguments"] ?? .object([:])
            return await Running.shared.run(id: id) {
                await tool.invoke(arguments)
            }

        // Declared empty rather than unimplemented, so a host that lists them
        // gets an empty list instead of an error it has to interpret.
        case "resources/list":  return .object(["resources": .array([])])
        case "prompts/list":    return .object(["prompts": .array([])])

        default:
            throw RPCError.methodNotFound(method)
        }
    }

    private func reply(id: JSON, result: JSON) async {
        await wire.send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func reply(id: JSON, error: RPCError) async {
        var e: [String: JSON] = ["code": .int(error.code), "message": .string(error.message)]
        if let d = error.data { e["data"] = d }
        await wire.send(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(e)]))
    }
}

/// In-flight tool calls, so `notifications/cancelled` can actually stop one.
///
/// A folder scan is minutes of work. Without this, a cancellation would be
/// acknowledged and the process would keep decoding — a success signal with
/// nothing behind it, which is the single defect class this repository is about.
actor Running {
    static let shared = Running()
    private var tasks: [String: Task<JSON, Never>] = [:]

    private func key(_ id: JSON) -> String {
        switch id {
        case .int(let i): return "i:\(i)"
        case .string(let s): return "s:\(s)"
        default: return "?:\(id)"
        }
    }

    /// Returns `nil` when the request was cancelled, so the caller sends
    /// nothing at all. A cancelled request has no client-side entry left to
    /// correlate a reply against, and the binding forbids one.
    func run(id: JSON, _ body: @escaping @Sendable () async -> JSON) async -> JSON? {
        let k = key(id)
        let task = Task<JSON, Never> { await body() }
        tasks[k] = task
        let value = await task.value
        tasks[k] = nil
        return task.isCancelled ? nil : value
    }

    func cancel(_ id: JSON) {
        tasks[key(id)]?.cancel()
    }
}
