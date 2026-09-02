// The app's persistent settings — the GUI equivalent of config.py. Every
// value survives app restarts via UserDefaults; buildConfig() turns the lot
// into the ImportConfig the pipeline consumes.

import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {

    private static let defaults = UserDefaults.standard

    // MARK: - Journals

    @AppStorage("journalName") var journalName = "Tweets"
    @AppStorage("importReplies") var importReplies = true
    @AppStorage("replyJournalName") var replyJournalName = "Twitter Replies"

    // MARK: - Account

    /// Off means the account is gone forever: no tweet links are written.
    /// The username itself always comes from the archive.
    @AppStorage("accountStillExists") var accountStillExists = true

    // MARK: - Debug options

    @AppStorage("startDateEpoch") private var startDateEpoch: Double = 0
    @AppStorage("endDateEpoch") private var endDateEpoch: Double = 0
    /// Tweet IDs to import exclusively, separated however (see debugTweetIDs).
    @AppStorage("debugTweetIDsText") var debugTweetIDsText = ""

    /// The pickers work in calendar days; the pipeline thinks in naive UTC.
    /// Untouched pickers sit at the pipeline defaults = the whole archive.
    ///
    /// The defaults are built as *local* calendar days, because everything
    /// downstream (the pickers, utcDay(), debugFiltersActive) reads dates
    /// through the local calendar. A UTC-midnight default would land on the
    /// previous local day anywhere west of UTC — permanently flagging the
    /// untouched pickers as a debug filter and killing coverage recording.
    var startDate: Date {
        get { startDateEpoch > 0 ? Date(timeIntervalSince1970: startDateEpoch) : Self.localDay(2006, 3, 21) }
        set { startDateEpoch = newValue.timeIntervalSince1970; objectWillChange.send() }
    }

    var endDate: Date {
        get { endDateEpoch > 0 ? Date(timeIntervalSince1970: endDateEpoch) : Self.localDay(2069, 4, 20) }
        set { endDateEpoch = newValue.timeIntervalSince1970; objectWillChange.send() }
    }

    /// Local midnight of the given calendar day — utcDay() maps it to the
    /// exact pipeline default in every timezone.
    private static func localDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func resetDateRange() {
        startDateEpoch = 0
        endDateEpoch = 0
        objectWillChange.send()
    }

    var debugTweetIDs: Set<String> {
        Set(debugTweetIDsText
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init))
    }

    /// True when any debug option narrows the run — such runs never count as
    /// full coverage of the archive.
    var debugFiltersActive: Bool {
        !debugTweetIDs.isEmpty
            || Self.utcDay(startDate, endOfDay: false) != PipelineDates.date(2006, 3, 21)
            || Self.utcDay(endDate, endOfDay: true) != PipelineDates.date(2069, 4, 20).addingTimeInterval(86_399)
    }

    // MARK: - Limits

    @AppStorage("limitThreads") var limitThreads = false
    @AppStorage("maxThreadsToProcess") var maxThreadsToProcess = 100

    // MARK: - Options

    @AppStorage("importOrder") var importOrder: ImportOrder = .oldestFirst
    @AppStorage("ignoreRetweets") var ignoreRetweets = false
    @AppStorage("showTweetSource") var showTweetSource = true

    // MARK: - LLM titles

    @AppStorage("llmTitlesEnabled") var llmTitlesEnabled = true
    @AppStorage("llmTitlesForSingleTweets") var llmTitlesForSingleTweets = true
    @AppStorage("ollamaHost") var ollamaHost = "http://localhost:11434"
    @AppStorage("ollamaModelName") var ollamaModelName = "qwen3.5:9b-mlx"
    @AppStorage("ollamaTimeoutSeconds") var ollamaTimeout = 120
    @AppStorage("ollamaTitlePrompt") var ollamaTitlePrompt = ImportConfig.defaultTitlePrompt

    // MARK: - Pipeline config

    /// Converts a picker-chosen date to the same calendar day at UTC midnight.
    private static func utcDay(_ date: Date, endOfDay: Bool) -> Date {
        let local = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let midnight = PipelineDates.date(local.year!, local.month!, local.day!)
        // The end of the range is inclusive: anything posted on that day counts.
        return endOfDay ? midnight.addingTimeInterval(86_399) : midnight
    }

    /// A normal run goes over the whole archive — the ledger plus the recorded
    /// coverage point turn that into "only what's new". The Debug options
    /// (date range, specific tweet IDs) can narrow a run; those runs never
    /// record coverage.
    func buildConfig() -> ImportConfig {
        ImportConfig(
            journalName: journalName,
            replyJournalName: importReplies ? replyJournalName.pyTrimmedOrNil() : nil,
            maxThreadsToProcess: limitThreads && maxThreadsToProcess > 0 ? maxThreadsToProcess : nil,
            importOrder: importOrder,
            debugTweetIDs: debugTweetIDs,
            ignoreRetweets: ignoreRetweets,
            showTweetSource: showTweetSource,
            startDate: Self.utcDay(startDate, endOfDay: false),
            endDate: Self.utcDay(endDate, endOfDay: true),
            processTitlesWithLLM: llmTitlesEnabled,
            llmTitlesForSingleTweets: llmTitlesForSingleTweets,
            // Past ten images the extra ones cost prefill time without
            // sharpening a 3-to-8-word title; over the cap a random sample goes.
            llmMaxImages: 10,
            ollamaHost: ollamaHost,
            ollamaModelName: ollamaModelName,
            ollamaTimeout: TimeInterval(ollamaTimeout),
            ollamaTitlePrompt: ollamaTitlePrompt
        )
    }
}

extension String {
    /// Trimmed string, or nil when empty — for optional settings fields.
    func pyTrimmedOrNil() -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
