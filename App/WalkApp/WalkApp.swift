import SwiftUI

/// Walk — the proof sheet.
///
/// ONE WINDOW. It opens a video or a folder of them, runs the scan, and shows
/// what the engine found: a thumbnail, a timecode, and the measured numbers
/// behind each candidate. #496 in the operator's words: *"ideally it would show
/// me a proof sheet on screen."*
///
/// WHAT IS DELIBERATELY ABSENT, so a later session does not read the gaps as
/// unfinished work: no preferences, no onboarding, no settings panel, no
/// timeline editor. Handles and thresholds live on the CLI, which is where a
/// number you might want to record belongs.
///
/// AND THE BOUNDARY THIS SCREEN MUST NOT CROSS — RESTATED IN 0.5.0, BECAUSE THE
/// OLD WORDING WAS REVERSED BY A RULING. It used to end "Walk sorts and flags;
/// the judgment is his", which decision #513 overturned: the sheet's job IS to
/// render a coaching verdict, and the strapline "Every frame measured; none
/// judged" was what convicted the first one.
///
/// The boundary that survives is narrower and it is about WHERE the judgment
/// comes from. This screen must never score a frame itself or rank by a
/// measurement. Session #228 measured that the operator's best-selling
/// photograph fails nearly every technical metric taken on it — 66.57% shadow,
/// clipped at both ends, the highest noise floor and the smallest file of the
/// set. A tool that hid his best seller because it scored badly would be worse
/// than no tool. So the bands come from the criteria file (#499) and the numbers
/// sit underneath as evidence; with no criteria file the sheet says it cannot
/// judge, which is the one thing the measured-not-judged version never did.
/// THE SANDBOX IS OFF, DELIBERATELY, AND HERE IS THE TRADE.
///
/// Walk's job is to read the operator's archive, which lives across external
/// volumes and arbitrary folders, and it writes nothing. Under App Sandbox with
/// user-selected-read-only the file picker works, but the app can then only ever
/// be driven by hand: a path passed on the command line is denied, so there is
/// no way to run it against known material and SEE that the proof sheet renders
/// the right numbers. An app whose output cannot be verified against a known
/// answer is the thing this whole repository exists to avoid.
///
/// The cost is named rather than buried: this build has no distribution-grade
/// containment. Turning the sandbox back on is a real task before anyone but
/// its author runs it, and it will need a scriptable verification route that
/// survives the sandbox — most likely a security-scoped bookmark seeded once by
/// hand.
@main
struct WalkApp: App {
    /// `Walk.app --scan <path>` scans immediately. This is how the app gets
    /// verified against known material instead of asserted to work.
    static var launchScanPaths: [URL] {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--scan"), i + 1 < args.count else { return [] }
        return args[(i + 1)...].filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
    }

    var body: some Scene {
        WindowGroup("Walk") {
            ProofSheetView(launchPaths: Self.launchScanPaths)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
