import Foundation
import WalkKit

// walk-mcp — WalkKit over MCP stdio.
//
// THE THIRD FRONT DOOR, and per decision #507 the primary one. The operator's
// own sentence for what this is: "tell you go walk this folder while i'm talking
// to andy, and you tap in to the local resources to get it done". The engine
// runs here, on his machine, fast and free; the conversation is where the
// results land.
//
// Register it:
//   claude mcp add --scope user --transport stdio walk /path/to/walk-mcp
//
// Diagnostics, both off unless set:
//   WALK_MCP_VERBOSE=1          chatter on stderr
//   WALK_MCP_LOG=/path/file     every message in both directions, one per line
//
// --version and --selftest are the only arguments; anything else is ignored so
// that a host passing a stray flag does not take the server down.

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print(Walk.version)
    exit(0)
}

if arguments.contains("--selftest") {
    // Answers the two questions a registration actually depends on, without a
    // host: does the process start, and does it list its tools. Used by CI.
    let names = Tools.all.map(\.name).sorted().joined(separator: " ")
    print("walk-mcp \(Walk.version)")
    print("transport stdio")
    print("protocols \(Protocols.all.joined(separator: " "))")
    print("tools \(names)")
    exit(0)
}

let wire = Wire()
let server = Server(wire: wire)
wire.verbose("walk-mcp \(Walk.version) up; protocols \(Protocols.all.joined(separator: ", "))")

// Each message is handled on its own task. A folder scan is minutes of work and
// a host that could not get a `ping` answered — or a `notifications/cancelled`
// delivered — during one would have no way to tell a long scan from a hung
// process. Writes are serialized by the `Wire` actor, so concurrency here cannot
// interleave two messages on stdout.
await withTaskGroup(of: Void.self) { group in
    for await line in Stdin.lines() {
        group.addTask { await server.handle(line) }
    }
}

wire.verbose("stdin closed; exiting")
