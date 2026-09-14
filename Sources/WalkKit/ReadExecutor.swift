import Foundation
import Dispatch

/// The executor the video read path runs on, so that a blocking decode can never
/// park a Swift Concurrency cooperative thread.
///
/// WHY THIS EXISTS — MEASURED 2026-09-13, task #764. The suite wedged at 0.0%
/// CPU with TWELVE tests simultaneously blocked in
/// `AVAssetReaderOutput.Provider.next()` -> `_pthread_cond_wait`, every one of
/// them on `com.apple.root.default-qos.cooperative`; `hw.ncpu` was twelve. The
/// whole cooperative pool was parked and nothing was left to resume any of them.
/// `StallWatchdog` bounds that condition; it does not remove it, and
/// `--no-parallel` removes it only for the test process. `walk-mcp` handles every
/// MCP message on its own task in the same pool (`Sources/walk-mcp/main.swift`),
/// so enough concurrent scans starve the server the same way — and the stated
/// purpose of that task group, keeping a `ping` answerable during a long scan, is
/// exactly what starvation takes away.
///
/// THE VENDOR CONTRACT, and this is not a workaround of it but the mechanism it
/// provides. The cooperative pool's rule is forward progress: a thread in it must
/// not be blocked (Swift Forums, "Contract to not impede progress in concurrency
/// pool"; WWDC21 "Swift concurrency: Behind the scenes", which names semaphores
/// and condition variables as hiding a dependency from the runtime;
/// `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` exists to detect a violation).
/// Apple's own async provider blocks underneath an `await`, so the read path
/// cannot honour that rule on the cooperative pool. SE-0417 (Swift 6.0) is the
/// supported answer: a task executor preference moves the task and the
/// nonisolated async functions it calls onto a chosen executor, and the proposal
/// names isolating blocking I/O off the shared pool as its motivation. The
/// `DispatchQueue`-backed shape below is the proposal's own example.
///
/// A CONCURRENT DISPATCH QUEUE, not a fixed thread count. Blocking here is
/// expected, and Dispatch's overcommit pool grows a thread when one of ours
/// parks. A fixed-width pool of N would reproduce the same defect at N+1
/// concurrent passes — a smaller version of the bug, which is not a fix.
///
/// This is ALWAYS ON in every build. Unlike `StallWatchdog` it changes no
/// observable behaviour and kills nothing; it only decides which threads block.
public final class ReadExecutor: TaskExecutor, @unchecked Sendable {

    /// One per process. A pass is a short-lived object and the executor outlives
    /// all of them.
    public static let shared = ReadExecutor()

    private let queue = DispatchQueue(
        label: "io.omatic.walk.read",
        qos: .userInitiated,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem)

    public func enqueue(_ job: consuming ExecutorJob) {
        // `UnownedJob` because the job must cross into the Dispatch block; it is
        // run exactly once, which is the contract `enqueue` is given.
        let unowned = UnownedJob(job)
        queue.async { unowned.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    /// Run `body` with the read executor preferred, which is also in force for
    /// the nonisolated async calls it makes. Named so the read path reads as
    /// intent rather than as plumbing.
    public static func run<T>(_ body: () async throws -> sending T) async rethrows -> T {
        try await withTaskExecutorPreference(ReadExecutor.shared, operation: body)
    }
}
