// Step 2 of the flow: everything config.py used to be, as a form. The
// archive summary sits on top so the user can sanity-check what was loaded.
// Continue leads to the Retrieve step; the import itself starts from there.

import SwiftUI

struct ConfigureStepView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmReset = false
    @StateObject private var ollamaStatus = OllamaStatusController()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                archiveSection
                journalsSection
                optionsSection
                llmSection
                debugSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Back") { model.startOver() }
                    .secondaryActionButtonStyle()
                Spacer()
                Button("Continue") { model.goToRetrieve() }
                    .primaryActionButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(journalNameInvalid)
            }
            .padding(14)
        }
        .onAppear {
            model.refreshDayOneBinary()
            model.refreshImportPreview()
        }
        .onChange(of: settings.startDate) { model.refreshImportPreview() }
        .onChange(of: settings.endDate) { model.refreshImportPreview() }
        .onChange(of: settings.debugTweetIDsText) { model.refreshImportPreview() }
    }

    private var journalNameInvalid: Bool {
        settings.journalName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Which threads the limit takes, spelled out — the import order decides,
    /// and that picker lives in another section.
    private var limitSelectionNote: String {
        let count = max(settings.maxThreadsToProcess, 0)
        switch settings.importOrder {
        case .oldestFirst:
            return "Takes the \(count) oldest threads still to import. "
                + "Change “Import order” above to take the newest, or a random sample."
        case .newestFirst:
            return "Takes the \(count) newest threads still to import. "
                + "Change “Import order” above to take the oldest, or a random sample."
        case .random:
            return "Takes \(count) random threads out of everything still to import — "
                + "handy for previewing what entries will look like."
        }
    }

    /// A setting's explanatory note. Stack it with the setting in one row, so
    /// no separator line comes between them.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Sections

    @ViewBuilder
    private var archiveSection: some View {
        if let archive = model.archive {
            Section {
                LabeledContent("Account") {
                    Text(archive.archiveUsername.map { "@\($0)" } ?? "unknown")
                }
                LabeledContent("Tweets") {
                    Text("\(archive.tweets.count), in \(archive.threads.count) threads")
                }
                if let range = archive.threadDateRange {
                    LabeledContent("Covers") {
                        Text("\(Self.dayFormatter.string(from: range.lowerBound)) — \(Self.dayFormatter.string(from: range.upperBound))")
                    }
                }
                if archive.adoptedOrphans > 0 {
                    LabeledContent("Repaired") {
                        Text("\(archive.adoptedOrphans) self-replies whose parent tweet is gone")
                    }
                }
                if let status = statusText {
                    LabeledContent("Status") {
                        Text(status)
                            .multilineTextAlignment(.trailing)
                    }
                }
                ForEach(archive.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } header: {
                Text("Archive")
            } footer: {
                note("Progress is saved after every entry — pause, cancel, or quit anytime, and the next import picks up right where this one stopped.")
            }
        }
    }

    /// Which threads a binding per-run limit will pick — that's the import
    /// order's doing: the run sorts by it, then stops at the limit. Nil when
    /// the limit is off or wouldn't bite anyway.
    private var limitedSelection: String? {
        guard settings.limitThreads, settings.maxThreadsToProcess > 0,
              let preview = model.importPreview,
              preview.pending > settings.maxThreadsToProcess
        else { return nil }
        return "\(orderedCount(settings.maxThreadsToProcess)) of \(preview.pending) pending threads"
    }

    /// "the 100 oldest" / "the 100 newest" / "100 random".
    private func orderedCount(_ count: Int) -> String {
        switch settings.importOrder {
        case .oldestFirst: return "the \(count) oldest"
        case .newestFirst: return "the \(count) newest"
        case .random: return "\(count) random"
        }
    }

    /// The one-line verdict of what pressing the import button will do.
    private var statusText: String? {
        guard let preview = model.importPreview else { return nil }
        if !settings.debugTweetIDs.isEmpty {
            return "Debug run — \(preview.pending) thread\(preview.pending == 1 ? "" : "s") "
                + "matching the listed tweet IDs; the ledger is ignored, nothing is recorded"
        }
        if let limitedSelection {
            var parts = ["Limited run — importing \(limitedSelection)"]
            if preview.grownThreads > 0 {
                parts.append("\(preview.grownThreads) of them grew since their import "
                    + "and are re-imported in full")
            }
            if preview.alreadyImported > 0 {
                parts.append("\(preview.alreadyImported) already imported and skipped")
            }
            return parts.joined(separator: "; ")
        }
        if preview.alreadyImported == 0 {
            return "First import — all \(preview.newThreads) threads will be imported"
        }
        if preview.pending == 0 {
            let covered = model.lastCoveredDate.map {
                " (covered through \(Self.dayFormatter.string(from: $0)))"
            } ?? ""
            return "Everything in this archive is already in Day One\(covered) — nothing new to import"
        }
        var parts = ["\(preview.newThreads) new thread\(preview.newThreads == 1 ? "" : "s") to import"]
        if preview.grownThreads > 0 {
            parts.append("\(preview.grownThreads) grown since their import "
                + "(re-imported in full, with a reminder to delete the older copies)")
        }
        parts.append("\(preview.alreadyImported) already imported and skipped")
        return parts.joined(separator: "; ")
    }

    private var journalsSection: some View {
        Section {
            TextField("Journal for tweets", text: $settings.journalName)
            Toggle("Import replies too", isOn: $settings.importReplies)
            if settings.importReplies {
                TextField("Journal for replies", text: $settings.replyJournalName)
            }
            dayOneStatusRow
        } header: {
            Text("Journals")
        } footer: {
            note("Create these journals in Day One first — the CLI won't create them for you. "
                + "\nKeep the Day One app running during the import: it's what moves staged media into the entries.")
        }
    }

    /// One row confirming Day One and its CLI are ready — or what's missing.
    @ViewBuilder
    private var dayOneStatusRow: some View {
        if let binary = model.dayOneBinary, model.dayOneAppURL != nil {
            VStack(alignment: .leading, spacing: 4) {
                Label("Day One and its CLI are installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                note("Using \(binary)")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if model.dayOneAppURL == nil {
                    Label("The Day One app doesn't seem to be installed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Link("Get Day One", destination: URL(string: "https://dayoneapp.com")!)
                        .font(.footnote)
                }
                if model.dayOneBinary == nil {
                    Label("The Day One CLI isn't installed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    note("Install it from Day One's own guide, then come back — this screen re-checks automatically.")
                    Link("Open the install instructions",
                         destination: URL(string: "https://dayoneapp.com/guides/day-one-for-mac/command-line-interface-cli/")!)
                        .font(.footnote)
                }
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Picker("Import order", selection: $settings.importOrder) {
                Text("From oldest to newest").tag(ImportOrder.oldestFirst)
                Text("From newest to oldest").tag(ImportOrder.newestFirst)
                Text("Random (useful for previewing results)").tag(ImportOrder.random)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Skip retweets", isOn: $settings.ignoreRetweets)
                if let archive = model.archive {
                    note("You retweeted \(archive.retweetThreads) times")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("My account still exists", isOn: $settings.accountStillExists)
                note("Turn this off if your account is gone forever — entries then get no tweet links.")
            }
            Toggle("End entries with “Sent from <client>”", isOn: $settings.showTweetSource)
        }
    }

    private var llmSection: some View {
        Section {
            Toggle("Title entries with a local LLM", isOn: $settings.llmTitlesEnabled)
            if settings.llmTitlesEnabled {
                ollamaStatusRow
                    .task(id: "\(settings.ollamaHost)|\(settings.ollamaModelName)") {
                        await ollamaStatus.watch(
                            host: settings.ollamaHost, model: settings.ollamaModelName)
                    }
                Toggle("Also title standalone tweets (slower)", isOn: $settings.llmTitlesForSingleTweets)
                TextField("Ollama server", text: $settings.ollamaHost)
                TextField("Model", text: $settings.ollamaModelName)
                DisclosureGroup("Title prompt") {
                    TextEditor(text: $settings.ollamaTitlePrompt)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 140)
                    Button("Reset to default") {
                        settings.ollamaTitlePrompt = ImportConfig.defaultTitlePrompt
                    }
                    .secondaryActionButtonStyle()
                }
            }
        } header: {
            Text("AI titles")
        } footer: {
            if settings.llmTitlesEnabled {
                Text("Titles come out like “Expressed frustration at airport security”; when the model isn't sure — or Ollama isn't reachable — the plain category title is kept, and the import carries on either way.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One live row saying whether titles will actually work: server up, model
    /// pulled — with the fix a click away when not. Updates by itself (see
    /// OllamaStatusController.watch).
    @ViewBuilder
    private var ollamaStatusRow: some View {
        switch ollamaStatus.state {
        case .unknown, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking Ollama…")
                    .foregroundStyle(.secondary)
            }

        case .ready(let model, let vision, let version):
            VStack(alignment: .leading, spacing: 4) {
                Label("Ollama\(version.isEmpty ? "" : " \(version)") is serving \(model)",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                note(vision
                    ? "The model has vision — attached photos are shown to it when titling."
                    : "This model can't see images — titles come from the tweet text alone.")
            }

        case .modelMissing(let requested, let installed):
            VStack(alignment: .leading, spacing: 6) {
                Label("Ollama is running, but “\(requested)” isn't pulled",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if !installed.isEmpty {
                    note("Pulled so far: \(installed.joined(separator: ", ")) — type one of "
                        + "those into the Model field, or download the one you asked for.")
                }
                HStack {
                    Button("Download \(requested)") { ollamaStatus.pull() }
                        .secondaryActionButtonStyle()
                    note("…or run `ollama pull \(requested)` in Terminal.")
                }
            }

        case .pulling(let status, let fraction, let completed, let total):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let fraction {
                        ProgressView(value: fraction)
                        Text(pullByteCount(completed: completed, total: total))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel") { ollamaStatus.cancelPull() }
                        .secondaryActionButtonStyle()
                }
                note("\(status.prefix(1).uppercased() + status.dropFirst()) — safe to cancel, "
                    + "the download resumes where it left off.")
            }

        case .pullFailed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Download failed: \(message)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                HStack {
                    Button("Try Again") { ollamaStatus.pull() }
                        .secondaryActionButtonStyle()
                    Button("Dismiss") { ollamaStatus.dismissFailure() }
                        .secondaryActionButtonStyle()
                }
            }

        case .notRunning(.app):
            VStack(alignment: .leading, spacing: 6) {
                Label("Ollama is installed but isn't running", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Button("Launch Ollama") { ollamaStatus.launchApp() }
                        .secondaryActionButtonStyle()
                    note("This row turns green by itself once the server is up.")
                }
            }

        case .notRunning(.cli(let path)):
            VStack(alignment: .leading, spacing: 4) {
                Label("Ollama is installed but isn't running", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                note("Start it with `ollama serve` in Terminal (found at \(path)) — "
                    + "this row updates by itself.")
            }

        case .notRunning(.notInstalled):
            VStack(alignment: .leading, spacing: 6) {
                Label("Ollama isn't installed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Link("Get Ollama", destination: URL(string: "https://ollama.com/download")!)
                    .font(.footnote)
                note("Install the app and open it once — this row updates by itself. "
                    + "Or turn AI titles off; entries then keep their plain category titles.")
            }

        case .notRunning(.remote(let host)):
            VStack(alignment: .leading, spacing: 4) {
                Label("Can't reach the Ollama server at \(host)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                note("Check that the server is running and the address is right — "
                    + "this row keeps retrying by itself.")
            }
        }
    }

    private func pullByteCount(completed: Int64?, total: Int64?) -> String {
        guard let completed, let total else { return "" }
        let format = ByteCountFormatter()
        format.countStyle = .file
        return "\(format.string(fromByteCount: completed)) of \(format.string(fromByteCount: total))"
    }

    private var debugSection: some View {
        Section("Debug options") {
            DatePicker("Import from", selection: $settings.startDate, displayedComponents: .date)
            VStack(alignment: .leading, spacing: 4) {
                DatePicker("Import until", selection: $settings.endDate, displayedComponents: .date)
                note("Only threads that started between these days (inclusive) are considered.")
            }

            DisclosureGroup("Specific tweets only") {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $settings.debugTweetIDsText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 80)
                    note("One tweet ID per line (spaces and commas work too). When the list isn't empty, only threads containing these tweets are imported — the ledger is ignored, so they import every time and nothing is recorded as done.")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Limit threads per run", isOn: $settings.limitThreads)
                if settings.limitThreads {
                    TextField("Max threads", value: $settings.maxThreadsToProcess, format: .number)
                    note(limitSelectionNote)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Button("Reset Previous Run Data…", role: .destructive) { confirmReset = true }
                    .disabled(!model.hasPreviousRunData || model.isImporting)
                note("Forgets what was already imported for this account — the ledger and the coverage record. Entries already in Day One stay where they are, so the next import will bring everything in again, duplicating them.")
            }
        }
        .confirmationDialog(
            "Reset previous run data?",
            isPresented: $confirmReset
        ) {
            Button("Reset", role: .destructive) { model.resetPreviousRunData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app will forget every imported thread for this account. Entries already in Day One are not touched — importing again will duplicate them.")
        }
    }
}
