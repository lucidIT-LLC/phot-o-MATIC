import Foundation

/// A bound on decode progress that HOLDS when Swift Concurrency cannot help.
///
/// WHY THIS IS NOT `.timeLimit`. Measured 2026-09-13: the suite wedged with
/// TWELVE tests simultaneously blocked in `AVAssetReaderOutput.Provider.next()`
/// -> `_pthread_cond_wait`, every one of them on
/// `com.apple.root.default-qos.cooperative`. `hw.ncpu` on that machine is
/// twelve. The entire Swift Concurrency cooperative pool was parked, which is
/// a forward-progress violation: the pool's contract is that a thread in it
/// always makes progress, and Apple's own async provider breaks it by blocking
/// on a condition variable underneath an `await`.
///
/// `.timeLimit(.minutes(10))` sat on the wedged test and never fired -- 29
/// minutes past a 10 minute limit. The usual explanation is that a pthread
/// condvar is not cancellable, and that is true but incomplete. The deeper
/// reason is that the limit's own enforcement is a Swift Concurrency task, and
/// it needs a cooperative thread to run on. There were none. THE BOUND WAS
/// STARVED BY THE SAME CONDITION IT EXISTED TO CATCH.
///
/// So this watchdog runs on a dedicated `Thread`, owned by nothing, scheduled
/// by the kernel. It cannot be starved by the pool it is watching.
///
/// OFF UNLESS ASKED. Walk ships as a CLI and an MCP server; a library that
/// kills the host process on a slow read would be indefensible. It arms only
/// when `WALK_TEST_WATCHDOG_SECONDS` is set, which `make test` does and
/// production never does.
public enum StallWatchdog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastBeat = DispatchTime.now().uptimeNanoseconds
    nonisolated(unsafe) private static var armed = false
    nonisolated(unsafe) private static var limitNanos: UInt64 = 0
    nonisolated(unsafe) private static var activePasses = 0

    /// The environment variable that arms it. Unset means no watchdog at all.
    public static let envKey = "WALK_TEST_WATCHDOG_SECONDS"

    /// Record progress. Called per delivered frame; cheap and lock-guarded.
    public static func beat() {
        guard armed else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock(); lastBeat = now; lock.unlock()
    }

    /// A pass has started reading. THE WATCHDOG ONLY JUDGES WHILE ONE IS OPEN.
    ///
    /// Without this it measured the wrong thing: `beat()` fires per decoded
    /// frame, so a stretch of non-video tests produces no beats at all, and a
    /// suite that simply had slow unit tests would be aborted for a stall that
    /// never happened. A watchdog with a false-positive mode is worse than
    /// none -- it would be switched off within the week, and then the real
    /// stall comes back unguarded.
    public static func passBegan() {
        guard armed else { return }
        lock.lock()
        activePasses += 1
        lastBeat = DispatchTime.now().uptimeNanoseconds   // fresh deadline
        lock.unlock()
    }

    /// A pass has finished, been cancelled, or been deallocated.
    public static func passEnded() {
        guard armed else { return }
        lock.lock()
        activePasses = Swift.max(0, activePasses - 1)
        lastBeat = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    /// Start the watchdog if the environment asks for one. Idempotent.
    public static func armIfRequested() {
        lock.lock()
        defer { lock.unlock() }
        guard !armed,
              let raw = ProcessInfo.processInfo.environment[envKey],
              let seconds = Double(raw), seconds > 0 else { return }
        armed = true
        limitNanos = UInt64(seconds * 1_000_000_000)
        lastBeat = DispatchTime.now().uptimeNanoseconds

        // A REAL THREAD, deliberately. Not a Task, not a DispatchQueue backed by
        // the cooperative pool, not a timer that needs a runloop serviced by a
        // starved executor. The whole point is to survive the starvation.
        let t = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                lock.lock()
                let since = DispatchTime.now().uptimeNanoseconds &- lastBeat
                let limit = limitNanos
                let active = activePasses
                lock.unlock()
                guard active > 0, since > limit else { continue }
                let secs = Double(since) / 1e9
                FileHandle.standardError.write(Data("""

                    ========================================================
                    WALK STALL WATCHDOG: \(active) read pass(es) open and no decoded \
                    frame for \(String(format: "%.1f", secs))s \
                    (limit \(String(format: "%.1f", Double(limit) / 1e9))s).

                    This is the cooperative-pool starvation described in
                    StallWatchdog.swift. Sample the process to confirm: expect
                    threads blocked in AVAssetReaderOutput.Provider.next() ->
                    _pthread_cond_wait on com.apple.root.default-qos.cooperative.

                    Aborting so this reports as a FAILURE rather than a hang.
                    A hang writes no output and reads like a job that never ran.
                    ========================================================

                    """.utf8))
                // _exit, not exit: atexit handlers would run on the same starved
                // runtime and could block, which would turn this bound back into
                // the hang it exists to replace.
                _exit(70)   // EX_SOFTWARE
            }
        }
        t.name = "walk.stall-watchdog"
        t.qualityOfService = .userInitiated
        t.start()
    }
}
