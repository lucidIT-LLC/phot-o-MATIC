import Testing
import Foundation
@testable import WalkKit

// TASK #764's PRODUCTION HALF, MECHANIZED.
//
// The defect was never a test defect. `AVAssetReaderOutput.Provider.next()`
// blocks underneath its `await`, and on a cooperative thread that violates the
// pool's forward-progress contract. Twelve concurrent passes on a twelve-core
// machine parked the whole pool: twelve tests blocked in `next()` ->
// `_pthread_cond_wait` on `com.apple.root.default-qos.cooperative`, nothing left
// to resume any of them, and `.timeLimit` starved by the condition it existed to
// catch. `--no-parallel` hides it in the test process and does nothing for
// `walk-mcp`, which handles every message on its own task in that same pool.
//
// So this measures the thing that actually has to be true: WITH MORE READ PASSES
// IN FLIGHT THAN THE MACHINE HAS CORES, AN ORDINARY COOPERATIVE TASK STILL RUNS.
// The canary is what a host's `ping` is.
//
// HOW IT FAILS. With the fix it fails as an assertion on the measured gap. Without
// it the process wedges instead, and `StallWatchdog` — armed by `make test` — turns
// that into `_exit(70)` with the pass count in the message. Both are a red run;
// only one of them is a sentence. That is why the watchdog stays even though the
// executor removes the cause.
@Test(.enabled(if: KnownAnswer.available))
func concurrentReadPassesDoNotParkTheCooperativePool() async throws {
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let readers = max(4, cores * 2)          // deliberately oversubscribed
    let framesEach = 40

    // The canary lives on the cooperative pool and nowhere else. It does NOT
    // inherit a read-executor preference: `Task.detached` does not inherit one
    // (SE-0417), and none is set at this scope anyway.
    let ticks = TickCounter()
    let canary = Task.detached {
        while !Task.isCancelled {
            ticks.tick()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // An observer on a REAL thread, for the same reason StallWatchdog is on one:
    // a cooperative observer of cooperative starvation cannot report it.
    let observer = GapObserver(ticks: ticks)
    observer.start()

    await withTaskGroup(of: Int.self) { group in
        for _ in 0..<readers {
            group.addTask {
                guard let reader = try? await VideoReader(url: KnownAnswer.url),
                      let pass = try? reader.pass(frames: 1000..<(1000 + framesEach))
                else { return 0 }
                defer { pass.cancel() }
                var n = 0
                while n < framesEach, let _ = try? await pass.next() { n += 1 }
                return n
            }
        }
        var total = 0
        for await n in group { total += n }
        #expect(total > 0, "no frames were decoded at all; the measurement below would be vacuous")
    }

    let worst = observer.stop()
    canary.cancel()

    // 2 s is generous by two orders of magnitude — the canary aims at 10 ms — and
    // deliberately so: this is a starvation detector, not a latency budget, and a
    // tight bound would make it flaky on a loaded machine and then be deleted.
    #expect(worst < 2.0, """
        the cooperative pool stalled for \(String(format: "%.2f", worst))s while \
        \(readers) read passes were in flight on a \(cores)-core machine. That is \
        task #764: the read path is blocking cooperative threads again. Check that \
        VideoReader.Pass.next() still goes through ReadExecutor.run.
        """)
}

/// A counter written from a cooperative task and read from a plain thread.
final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func tick() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Samples the canary from a dedicated thread and keeps the worst gap between
/// observed ticks. Scheduled by the kernel, so a parked cooperative pool cannot
/// stop it measuring.
final class GapObserver: @unchecked Sendable {
    private let ticks: TickCounter
    private let lock = NSLock()
    private var worstSeconds = 0.0
    private var running = true

    init(ticks: TickCounter) { self.ticks = ticks }

    func start() {
        let t = Thread { [self] in
            var lastCount = ticks.count
            var lastChange = DispatchTime.now().uptimeNanoseconds
            while true {
                Thread.sleep(forTimeInterval: 0.05)
                lock.lock(); let go = running; lock.unlock()
                if !go { return }
                let now = DispatchTime.now().uptimeNanoseconds
                let c = ticks.count
                if c != lastCount {
                    let gap = Double(now &- lastChange) / 1e9
                    lock.lock(); worstSeconds = Swift.max(worstSeconds, gap); lock.unlock()
                    lastCount = c; lastChange = now
                } else {
                    let gap = Double(now &- lastChange) / 1e9
                    lock.lock(); worstSeconds = Swift.max(worstSeconds, gap); lock.unlock()
                }
            }
        }
        t.name = "walk.test.gap-observer"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func stop() -> Double {
        lock.lock(); running = false; let w = worstSeconds; lock.unlock()
        return w
    }
}
