import SwiftUI
import UniformTypeIdentifiers
import WalkKit

struct ProofSheetView: View {
    var launchPaths: [URL] = []
    @State private var model = ProofSheetModel()
    @State private var importing = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importing = true
                } label: {
                    Label("Open Video or Folder", systemImage: "folder")
                }
                .help("Open a video file or a folder of them")
            }
            if case .scanning = model.state {
                ToolbarItem(placement: .primaryAction) {
                    Button("Stop") { model.cancel() }
                }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.open(urls) }
        }
        .navigationTitle("Walk \(Walk.version)")
        .task {
            if !launchPaths.isEmpty { model.open(launchPaths) }
        }
    }

    // MARK: sidebar — clips and the scan's own numbers

    private var sidebar: some View {
        List(selection: Binding(get: { model.selectedClip },
                                set: { model.selectedClip = $0; model.selectedMoment = nil })) {
            if model.clips.isEmpty { emptySidebar }
            ForEach(model.clips) { clip in
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.url.lastPathComponent)
                        .font(.system(.body, design: .default)).lineLimit(1).truncationMode(.middle)
                    Text("\(clip.moments.count) candidate\(clip.moments.count == 1 ? "" : "s") · \(clip.decodedFrames) frames")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.1f fps scan · %@ bound", clip.framesPerSecond, clip.boundBy))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .tag(clip.id)
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        .safeAreaInset(edge: .bottom) { status }
    }

    private var emptySidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing open").font(.headline)
            Text("Open a video or a folder. Walk scans every frame, flags the moments that rise above the clip's own baseline, and shows you the numbers.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .scanning(let clip, let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text("Scanning \(clip)").font(.caption).lineLimit(1).truncationMode(.middle)
                ProgressView(value: min(max(progress, 0), 1))
            }
            .padding(10)
            .background(.bar)
        case .done:
            EmptyView()
        case .failed(let message):
            Text(message)
                .font(.caption).foregroundStyle(.red)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    // MARK: detail — the proof sheet itself

    @ViewBuilder private var detail: some View {
        if let clip = model.currentClip {
            VStack(spacing: 0) {
                clipHeader(clip)
                Divider()
                if model.visibleMoments.isEmpty {
                    nothingFound(clip)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 14)],
                                  spacing: 14) {
                            ForEach(model.visibleMoments) { moment in
                                MomentCard(moment: moment,
                                           selected: moment.id == model.selectedMoment)
                                    .onTapGesture { model.selectedMoment = moment.id }
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .inspector(isPresented: .constant(model.moment != nil)) {
                if let moment = model.moment {
                    MomentDetail(moment: moment)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Walk", systemImage: "bolt.horizontal.circle")
            } description: {
                Text("Open a video or a folder. Walk measures every frame, then coaches the moments it finds — what is sellable as shot, what has potential with one change, and what is not worth the trouble. The verdict needs a criteria file; without one it says so rather than pretending.")
                    .multilineTextAlignment(.center)
            } actions: {
                Button("Open…") { importing = true }
            }
        }
    }

    private func clipHeader(_ clip: ClipResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(clip.url.lastPathComponent).font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if clip.info.isHLGBT2020 {
                    Text("HLG BT.2020 · \(clip.info.bitDepth.map(String.init) ?? "?")-bit")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text(String(format: "%d × %d · %.2f fps · %.2f s · %d frames decoded in %.2f s (%.0f fps)",
                        clip.info.width, clip.info.height, clip.info.fps, clip.info.seconds,
                        clip.decodedFrames, clip.scanSeconds, clip.framesPerSecond))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(clip.verdict).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "threshold %.3f%% (statistics %.3f%%, floor 1.000%%, %@ bound)%@",
                        clip.threshold * 100, clip.statisticalThreshold * 100, clip.boundBy,
                        clip.scaleCollapsed ? " · the clip supplies no noise scale, so the floor is doing all the work" : ""))
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            if !clip.missingIndices.isEmpty {
                Text("\(clip.missingIndices.count) frame indices were never delivered by the decoder")
                    .font(.caption).foregroundStyle(.orange)
            }
            CoachingPanel(report: clip.coaching)
            HStack(spacing: 8) {
                Text("show lightning ≥").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.minimumLightning },
                                      set: { model.minimumLightning = $0 }), in: 0...1)
                    .frame(width: 160)
                Text(String(format: "%.2f", model.minimumLightning))
                    .font(.caption2.monospaced()).frame(width: 34)
                Text("— \(model.visibleMoments.count) of \(clip.moments.count) shown")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            // #740 DEFECT 4 — CONFIDENCE IS A RANK AND THIS CONTROL TURNS IT
            // INTO A GATE, SO THE COST IS NAMED THE MOMENT IT IS NON-ZERO.
            //
            // MEASURED on clip 0012: frame 1272 is a genuine distant bolt
            // striking a far ridge through rain — confirmed against frame 1271,
            // which is empty — and it scores 0.0044. Its Y max of 945 is
            // identical to no-event frames, so luminance missed it too; it
            // reached the candidate list only because the trigger fired for an
            // unrelated reason. Any sane-looking floor discards it. That is the
            // honest limit on "classification beats luminance" (#504):
            // classification beats it on RANKING what you already have, not on
            // RECALL. The slider stays — it is the operator's — and it starts at
            // zero, but it no longer hides what it costs.
            if model.minimumLightning > 0 {
                Text("A filter above zero is a gate on a number that is only reliable as a rank. On this clip a real distant strike scores 0.0044 with a peak indistinguishable from an empty frame — a floor of 0.05 throws it away and reports nothing missing.")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private func nothingFound(_ clip: ClipResult) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text(clip.moments.isEmpty ? "Nothing found" : "Nothing above this filter")
                .font(.headline)
            Text(clip.moments.isEmpty
                 ? "No frame rose above the threshold. That is an answer, not an empty screen — the detector can report an absence."
                 : "\(clip.moments.count) candidate\(clip.moments.count == 1 ? "" : "s") measured, all below the lightning filter. Drag it back to zero to see them.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - the coaching verdict (#513)

/// The sheet's headline claim, and the one #513 replaced.
///
/// 0.4.1 shipped "Every frame measured; none judged." as the product's promise.
/// It was true and it was the wrong promise: a light meter measures, a coach
/// judges, says why, and asks where you were going. This panel therefore leads
/// with the VERDICT — and when there is none, it leads with the absence and the
/// reason, which is the one thing the old sheet never did.
private struct CoachingPanel: View {
    let report: Coaching.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: report.available ? "checkmark.seal" : "questionmark.circle")
                    .foregroundStyle(report.available ? .green : .orange)
                Text(report.available ? "COACHING VERDICT" : "NO COACHING VERDICT")
                    .font(.caption.weight(.semibold))
                Text(report.headline).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if report.available {
                ForEach(Coaching.Band.allCases.sorted { $0.order < $1.order }, id: \.self) { band in
                    let group = report.verdicts(in: band)
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(band.label) — \(group.count)")
                                .font(.caption2.weight(.semibold))
                            ForEach(group, id: \.frame) { v in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("frame \(v.frame) · \(v.reason)").font(.caption2)
                                    if let change = v.change {
                                        Text("with this: \(change)").font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    // REQUIRED, NOT DECORATION — #513.
                                    if let q = v.forwardQuestion {
                                        Text(q).font(.caption2.italic())
                                    }
                                    Text("next flight: \(v.nextFlight)").font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("rule \(v.ruleID) — \(v.origin)").font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                if !report.uncovered.isEmpty {
                    Text("\(report.uncovered.count) candidate\(report.uncovered.count == 1 ? "" : "s") no rule covered — left unjudged rather than banded")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text(report.unavailableReason ?? "reason not recorded")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Coaching.Band.allCases.sorted { $0.order < $1.order }, id: \.self) { band in
                    Text("\(band.label) — \(band.promise)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(report.lessons, id: \.id) { lesson in
                VStack(alignment: .leading, spacing: 1) {
                    Text(lesson.headline).font(.caption2.weight(.medium))
                    Text(lesson.origin).font(.caption2).foregroundStyle(.tertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - one card

private struct MomentCard: View {
    let moment: Moment
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let image = moment.thumbnail {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary).aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay { Text("no thumbnail").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(moment.timecode)
                    .font(.caption2.monospaced()).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white).padding(6)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("frame \(moment.frame)").font(.caption.monospaced().weight(.medium))
                    Spacer()
                    Text(String(format: "%+.2f%%", moment.relativeRise * 100))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                // #740 DEFECT 1 — σ IS OFF THE CARD ON PURPOSE.
                //
                // It used to sit here, first in a row of metrics, directly under
                // the rise percentage. sigma = relativeRise / robustSigma and
                // robustSigma is ONE CONSTANT for the clip, so on a single
                // clip's sheet σ is the percentage above it multiplied by a
                // fixed number: it adds no information to this card and it reads
                // as a second instrument agreeing with the first. A card at
                // thumbnail scale has no room to explain a derivation, so the
                // honest move is not to assert it here. It stays in the detail
                // pane, where the derivation is stated next to it, and it is
                // still in the JSON for cross-clip comparison.
                HStack(spacing: 10) {
                    if let y = moment.yMean { metric("Y~", String(format: "%.1f", y)) }
                    if let m = moment.yMax {
                        metric("peak", "\(m)\(moment.yClipped ? "!" : "")")
                    }
                }
                HStack(spacing: 4) {
                    Text("lightning").font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "%.4f", moment.lightning))
                        .font(.caption2.monospaced().weight(.semibold))
                    Spacer()
                    if moment.mergedFrames > 1 {
                        Text("\(moment.mergedFrames) frames merged")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(8)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption2.monospaced())
        }
    }
}

// MARK: - the numbers behind one moment

private struct MomentDetail: View {
    let moment: Moment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let image = moment.thumbnail {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text("Frame \(moment.frame) · \(moment.timecode)").font(.headline)

                group("Measured") {
                    row("time", String(format: "%.4f s", moment.time))
                    row("luma, linear BT.2020", String(format: "%.6f", moment.ciLuma))
                    row("local baseline", String(format: "%.6f", moment.baseline))
                    row("delta", String(format: "%+.6f", moment.ciLuma - moment.baseline))
                    row("relative rise, linear BT.2020", String(format: "%+.3f%%", moment.relativeRise * 100))
                    row("that rise ÷ the clip's robust σ", String(format: "%.1f", moment.sigma))
                    if let y = moment.yMean {
                        row("Y mean, 10-bit code (stride \(ProofSheetModel.appYPlaneStride))",
                            String(format: "%.2f", y))
                    }
                    if let m = moment.yMax {
                        row("Y peak", "\(m)\(moment.yClipped ? "  CLIPPED" : " of 1023")")
                    }
                    if moment.mergedFrames > 1 {
                        row("frames merged to this peak", "\(moment.mergedFrames)")
                    }
                }

                group("Vision — built-in taxonomy, no model file") {
                    if moment.labels.isEmpty {
                        Text("not classified").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(moment.labels, id: \.0) { label in
                        row(label.0, String(format: "%.4f", label.1))
                    }
                }

                Text("These are the measurements under the verdict, not the verdict. Ranking by them is how the first scan of the storm clip lost two real strikes: luminance finds bright flashes, classification finds lightning.")
                    .font(.caption2).foregroundStyle(.secondary)

                // #740 DEFECTS 1 AND 2, AT THE ONE PLACE ON THE SHEET WITH ROOM
                // TO STATE THEM. Both are cases of a number read without the
                // thing that makes it mean anything: σ without its derivation
                // reads as corroboration, and rise without its colour space
                // reads as comparable to the Y-plane figure two rows below it.
                Text("Two numbers above are easy to misread. The σ figure is that rise divided by one constant for the whole clip, so on this clip it is the rise line rescaled — the same ranking, not a second measurement agreeing with it; it earns its keep only when comparing candidates across different clips. And the rise is measured in pinned linear BT.2020 light, while Y mean and Y peak are gamma-encoded 10-bit code values: the two are different quantities and no single multiplier converts between them. On clip 0012, frame 2347 is +36.03% linear and +6.02% on the Y plane, while frame 2388 is +3.69% against +0.79%.")
                    .font(.caption2).foregroundStyle(.secondary)

                Text("The Y mean above is sampled every \(ProofSheetModel.appYPlaneStride)th row and column so a folder scans in seconds. `walk scan` reads every pixel; use it when the exact code value matters.")
                    .font(.caption2).foregroundStyle(.tertiary)

                Text(moment.clip.lastPathComponent)
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(2).truncationMode(.middle)
            }
            .padding(14)
        }
    }

    @ViewBuilder private func group(_ title: String,
                                    @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.caption.monospaced())
        }
    }
}
