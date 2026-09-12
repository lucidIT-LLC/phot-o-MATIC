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
// --version, --help and --selftest are the only arguments; anything else is
// ignored so that a host passing a stray flag does not take the server down.
//
// TASK #740's RED ITEM, AND IT DID NOT REPRODUCE.
//
// #740 recorded that `walk-mcp --version` "PRINTS NOTHING on 0.5.0 and exits
// silently" where 0.4.1 printed a version, and that `make install-mcp` was
// therefore reporting an empty version to the operator. MEASURED 2026-09-12
// against the installed 0.5.0 binary — sha256 ac5d3f38…, byte-identical to the
// release build, the same 1,009,096 bytes at 13:46 the task names — `--version`
// prints "0.5.0" and exits 0 through a TTY, a pipe, a `$(…)` substitution, a
// file redirect, and with stdin closed. Six bytes, every time. Nothing below was
// changed to make that work and the branch is untouched.
//
// WHAT DOES REPRODUCE, and is what a person running this by hand would have hit:
// `--help`, `-h`, an unknown flag and NO ARGUMENTS all printed nothing and
// exited 0. For no arguments that is CORRECT — this is an MCP stdio server whose
// caller is a host, not a person, and with stdin at EOF it has nothing to do but
// leave. The defect is that correct and crashed-on-startup were byte-identical
// from a prompt, which is this task's own subject in its plainest form: a
// reading that is silent read as a reading that is fine.
//
// So `--help` answers, a hand-run server says what it is on stderr instead of
// sitting mute, and an unrecognized argument says it was ignored rather than
// being swallowed. stdout stays reserved for the protocol — none of this goes
// there — and the ignore-and-keep-running contract above is unchanged.

let arguments = CommandLine.arguments

/// stderr, never stdout: stdout is the MCP frame channel and a stray line on it
/// corrupts the session for the host.
func note(_ s: String) {
    FileHandle.standardError.write(Data(("walk-mcp: " + s + "\n").utf8))
}

let usage = """
walk-mcp \(Walk.version) — WalkKit over MCP stdio.

This is a server, not a command. It speaks MCP on stdin/stdout and is meant to
be launched by a host; run with no arguments and no host, it reads end-of-file
and exits, which is success and looks like nothing happening.

  --version    print \(Walk.version) and exit
  --help, -h   this text
  --selftest   start, list the tools, and exit — proves a registration will work

Register it with Claude Code:
  claude mcp add --scope user --transport stdio walk <path to this binary>

Environment:
  WALK_MCP_VERBOSE=1        chatter on stderr
  WALK_MCP_LOG=<path>       every message in both directions, one per line

Tools: \(Tools.all.map(\.name).sorted().joined(separator: ", "))
"""

if arguments.contains("--version") {
    print(Walk.version)
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
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

// An unrecognized argument is STILL IGNORED — a host passing a stray flag must
// not lose its server — but it is now named on stderr, so a typo is a visible
// typo instead of a binary that appears to accept anything.
let knownArguments: Set<String> = ["--version", "--help", "-h", "--selftest"]
let unrecognized = arguments.dropFirst().filter { !knownArguments.contains($0) }
if !unrecognized.isEmpty {
    note("ignoring unrecognized argument\(unrecognized.count == 1 ? "" : "s") "
         + "\(unrecognized.joined(separator: " ")) and starting anyway; --help lists what is accepted")
}

// STDIN IS A TERMINAL, so a person ran this rather than a host launching it.
// Say what the process is and what is about to happen, because the alternative —
// the behaviour #740 hit — is an instant silent exit that a person cannot tell
// apart from a crash.
if isatty(FileHandle.standardInput.fileDescriptor) == 1 {
    note("\(Walk.version) — MCP stdio server. No host is attached, so this will read "
         + "end-of-file and exit; that is success, not a failure. --help explains.")
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
