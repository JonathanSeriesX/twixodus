// Step 3 of the flow: optionally pull what the archive is missing from
// Twitter's public embed endpoint — the full text (and attachments) of
// truncated retweets, the content of quoted tweets, and media files the
// exporter dropped. Entirely skippable: Start Import works with or without
// a retrieval run. Everything fetched lands in a folder NEXT TO the archive
// (twitter-…-hydration) and is reused by every later run and re-import.

import SwiftUI

struct RetrieveStepView: View {
    @EnvironmentObject private var model: AppModel
    /// The log is the running view, and a manual detour afterwards — a
    /// finished run lands back on the summary, which is the useful screen.
    @State private var showingLog = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isRetrieving {
                runHeader
                Divider()
                logView
            } else if showingLog {
                logHeader
                Divider()
                logView
            } else {
                planView
            }

            Divider()
            bottomBar
        }
        .onAppear { model.refreshHydrationPlan() }
        .onChange(of: model.isRetrieving) { _, running in
            // A finished run returns to the plan, now showing what it did.
            if !running { showingLog = false }
        }
    }

    // MARK: - The plan (before a run)

    private var planView: some View {
        VStack(spacing: 0) {
            Form {
                if let summary = model.retrieveSummary {
                    Section {
                        Label(summary, systemImage: model.retrieveHadTrouble
                            ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(model.retrieveHadTrouble ? .orange : .green)
                    } header: {
                        Text("Last run")
                    }
                }
                Section {
                    planRows
                } header: {
                    Text("What can be retrieved")
                } footer: {
                    Text(planFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Spacer(minLength: 0)
        }
    }

    /// Kept out of the `Text(...)` call on purpose. As one long `+` chain
    /// with interpolations passed straight to an overloaded initializer, this
    /// string made older Swift compilers (Xcode 16) give up type-checking the
    /// expression. A plain `String` property is resolved on its own, cheaply.
    private var planFooter: String {
        let folder = model.hydrationStore?.folder.lastPathComponent ?? "…-hydration"
        return """
        Covers the \(model.retrieveScope) tweets the next import will actually bring in — \
        narrow the run (date range, per-run limit, specific tweets) and this narrows with it.

        Uses Twitter's public embed endpoint — no login or API key. One polite request \
        per item (~2 per second), so large batches take a few minutes. Everything is saved \
        next to your archive in “\(folder)” and reused by every later run — the archive \
        itself is never modified.
        """
    }

    @ViewBuilder
    private var planRows: some View {
        if let plan = model.hydrationPlan {
            row(icon: "arrow.2.squarepath",
                title: "Truncated retweets",
                subtitle: "Retweets the archive cut at 140 characters — their full text "
                    + "and attachments can be recovered",
                pending: plan.pendingRetweets.count, done: plan.retweetsDone,
                unavailable: plan.retweetsUnavailable, incomplete: plan.retweetsIncomplete)
            row(icon: "quote.opening",
                title: "Quoted tweets",
                subtitle: "Tweets you quoted — retrieved and shown as a blockquote "
                    + "under your comment",
                pending: plan.pendingQuotes.count, done: plan.quotesDone,
                unavailable: plan.quotesUnavailable, incomplete: 0)
            row(icon: "photo.on.rectangle.angled",
                title: "Missing media files",
                subtitle: "Photos and videos your archive references but doesn't "
                    + "contain — still downloadable in full quality",
                pending: plan.pendingMedia.count, done: plan.mediaDone,
                unavailable: 0, incomplete: 0)
            if plan.totalPending == 0, plan.totalRetryable == 0 {
                Label("Everything retrievable has been retrieved.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if plan.totalPending == 0 {
                let plural = plan.totalRetryable == 1 ? "" : "s"
                Label("\(plan.totalRetryable) item\(plural) didn't come through. Most of those are genuinely deleted or private.",
                      systemImage: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Scanning the archive…")
                .foregroundStyle(.secondary)
        }
    }

    private func row(icon: String, title: String, subtitle: String,
                     pending: Int, done: Int, unavailable: Int, incomplete: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(pending)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(pending > 0 ? .primary : .secondary)
                if done > 0 || unavailable > 0 || incomplete > 0 {
                    Text(doneNote(done: done, unavailable: unavailable, incomplete: incomplete))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func doneNote(done: Int, unavailable: Int, incomplete: Int) -> String {
        var parts: [String] = []
        if done > 0 { parts.append("\(done) already retrieved") }
        if unavailable > 0 { parts.append("\(unavailable) reported gone") }
        if incomplete > 0 { parts.append("\(incomplete) missing attachments") }
        return parts.joined(separator: ", ")
    }

    // MARK: - The run (progress + log)

    private var runHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.numericText())
                    .animation(.default, value: model.retrieveDone)
                Spacer()
                if model.retrieveTotal > 0 {
                    Text("\(Int((Double(model.retrieveDone) / Double(model.retrieveTotal) * 100).rounded()))%")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(
                value: Double(model.retrieveDone),
                total: Double(max(model.retrieveTotal, 1))
            )
            .progressViewStyle(.linear)
            HStack {
                Text(model.activity)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
        }
        .padding(20)
    }

    private var headline: String {
        if model.isRetrieving {
            return "Retrieved \(model.retrieveDone) of \(model.retrieveTotal)"
        }
        return model.retrieveSummary ?? "Done"
    }

    /// The header the log carries when it's opened by hand, after the run.
    private var logHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Retrieval log")
                .font(.title3.weight(.semibold))
            Spacer()
            if let summary = model.retrieveSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.retrieveLog) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .background(.quaternary.opacity(0.3))
            .onChange(of: model.retrieveLog.last?.id) { _, lastId in
                if let lastId {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    private func color(for kind: ImportLogKind) -> Color {
        switch kind {
        case .info: return .secondary
        case .thread: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if model.isRetrieving {
                Button {
                    model.togglePause()
                } label: {
                    Label(model.isPaused ? "Resume" : "Pause",
                          systemImage: model.isPaused ? "play.fill" : "pause.fill")
                        .frame(minWidth: 80)
                }
                .primaryActionButtonStyle()

                Button("Cancel", role: .cancel) { model.cancelRetrieval() }
                    .secondaryActionButtonStyle()

                Spacer()

                if model.isPaused {
                    Label("Paused — everything retrieved so far is already saved",
                          systemImage: "pause.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Back") { model.backToConfigure() }
                    .secondaryActionButtonStyle()

                // Only after a retrieval has actually run — there is no
                // "log of the retrieval" before that.
                if !model.retrieveLog.isEmpty {
                    Button(showingLog ? "Close Log" : "View Log") {
                        showingLog.toggle()
                    }
                    .secondaryActionButtonStyle()
                }

                if retryableCount > 0 {
                    Button("Retry \(retryableCount) Failed") {
                        model.startRetrieval(retryingFailures: true)
                    }
                    .secondaryActionButtonStyle()
                    .help("Asks again for the tweets recorded as gone and the attachments "
                        + "that failed to download — the endpoint refuses requests in ways "
                        + "that look just like a deleted tweet.")
                }

                Spacer()

                if model.dayOneBinary == nil {
                    Label("Install the Day One CLI to start", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                if pendingCount > 0 {
                    Button("Retrieve \(pendingCount) Item\(pendingCount == 1 ? "" : "s")") {
                        model.startRetrieval()
                    }
                    .primaryActionButtonStyle()
                }

                Button(importButtonTitle) { model.startImport() }
                    .modifier(ImportButtonStyle(prominent: pendingCount == 0))
                    .keyboardShortcut(pendingCount == 0 ? .defaultAction : nil)
                    .disabled(model.dayOneBinary == nil || nothingToImport)
            }
        }
        .padding(14)
    }

    private var pendingCount: Int {
        model.hydrationPlan?.totalPending ?? 0
    }

    private var retryableCount: Int {
        model.hydrationPlan?.totalRetryable ?? 0
    }

    private var nothingToImport: Bool {
        model.importPreview?.pending == 0
    }

    /// The same resume-aware title Configure used to carry ("Continue Import",
    /// "Import What's New"), with "Skip &" in front while retrieval is pending.
    private var importButtonTitle: String {
        let base: String
        if let preview = model.importPreview, preview.alreadyImported > 0, preview.pending > 0 {
            base = model.lastCoveredDate == nil ? "Continue Import" : "Import What's New"
        } else {
            base = "Start Import"
        }
        if pendingCount > 0, model.retrieveSummary == nil {
            return "Skip & \(base)"
        }
        return base
    }
}

/// The import button plays second fiddle while retrieval is still pending.
private struct ImportButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.primaryActionButtonStyle()
        } else {
            content.secondaryActionButtonStyle()
        }
    }
}
