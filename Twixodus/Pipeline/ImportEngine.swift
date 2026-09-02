// Steps 4–7 of the pipeline: select the threads for the date range, import
// them one entry at a time, and produce the delete-the-duplicates report.
// This is main.py's loop, reshaped for a GUI: it reports progress through
// callbacks and supports pausing and cancelling between entries.

import Foundation

/// Thread-safe pause/cancel flags shared between the UI and the import loop.
///
/// Cancellation lives here, not in Swift's task tree: the app runs the engine
/// on a detached task (to get off the main actor), and detached tasks don't
/// inherit cancellation from the task that awaits them.
public final class ImportControl {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false

    public init() {}

    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    public func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Clears both flags — called once at the start of every run.
    public func reset() {
        lock.lock()
        paused = false
        cancelled = false
        lock.unlock()
    }
}

public enum ImportLogKind {
    case info
    case thread  // the title line that opens each entry's log block
    case success
    case warning
    case error
}

public struct ImportCallbacks {
    public var log: (String, ImportLogKind) -> Void
    /// (imported so far, total pending in this run)
    public var progress: (Int, Int) -> Void
    /// A one-line description of what the engine is doing right now.
    public var activity: (String) -> Void

    public init(
        log: @escaping (String, ImportLogKind) -> Void = { _, _ in },
        progress: @escaping (Int, Int) -> Void = { _, _ in },
        activity: @escaping (String) -> Void = { _ in }
    ) {
        self.log = log
        self.progress = progress
        self.activity = activity
    }
}

public struct ImportRunResult: Sendable {
    public var importedCount = 0
    public var skippedAlreadyImported = 0
    /// Threads that Day One rejected (CLI failed). They are not recorded in
    /// the ledger, so the next run retries them.
    public var failedCount = 0
    /// Threads skipped by configuration: replies with no reply journal set,
    /// retweets when retweets are ignored. Recorded in the ledger as done.
    public var skippedNoJournal = 0
    public var totalPending = 0
    public var wasCancelled = false
    public var stoppedAtLimit = false
    /// The delete-the-duplicates reminder, when threads were re-imported.
    public var reimportReport: String?
}

public final class ImportEngine {

    private let config: ImportConfig
    private let context: ThreadCategorizer.Context
    private let ledger: ImportLedger
    private let dayOne: EntryPosting
    private let ollama: OllamaClient?
    private let control: ImportControl
    private let callbacks: ImportCallbacks

    /// Categorization mutates tweet text in place (RT prefixes are stripped),
    /// so a thread must be categorized at most once per loaded archive — even
    /// across several runs in the same app session. The cache keeps the result
    /// keyed by root tweet ID.
    private let categoryCache: CategoryCache

    public final class CategoryCache {
        var categories: [String: String] = [:]
        public init() {}
    }

    public init(
        config: ImportConfig,
        context: ThreadCategorizer.Context,
        ledger: ImportLedger,
        dayOne: EntryPosting,
        ollama: OllamaClient?,
        categoryCache: CategoryCache,
        control: ImportControl,
        callbacks: ImportCallbacks
    ) {
        self.config = config
        self.context = context
        self.ledger = ledger
        self.dayOne = dayOne
        self.ollama = ollama
        self.categoryCache = categoryCache
        self.control = control
        self.callbacks = callbacks
    }

    // MARK: - The run loop (main.py steps 4–7)

    public func run(threads allThreads: [TweetThread]) async -> ImportRunResult {
        var result = ImportRunResult()

        // ---- Step 4: pick which threads to import, and in what order ------
        // Debug mode: only the listed threads, imported every time — the
        // ledger is neither consulted nor written (main.py's tweets_to_debug).
        let debugMode = !config.debugTweetIDs.isEmpty
        var processedIDs = debugMode ? Set<String>() : ledger.loadProcessedIDs()
        if !debugMode {
            log("Loaded \(processedIDs.count) previously processed tweet IDs.\n")
        }

        // Selection lives in ThreadSelection, so the Retrieve step can ask
        // the same question and get the same answer.
        let runPlan = ThreadSelection.planRun(
            allThreads, config: config, processedIDs: processedIDs)
        let plan = runPlan.imports

        if debugMode {
            log("Debug mode: \(runPlan.consideredThreads) thread(s) match the listed tweet IDs.")
        }
        if runPlan.consideredThreads != runPlan.inRangeCount {
            log("Filtered down to \(runPlan.inRangeCount) threads within the specified date range.")
        }
        if runPlan.reimportCount > 0 {
            log("\(runPlan.reimportCount) previously imported thread(s) gained new tweets "
                + "and will be re-imported in full.")
        }

        // ---- Steps 5 & 6: import the planned threads, one entry each ------
        result.totalPending = countPendingImports(plan, processedIDs: processedIDs)
        // Pending threads the loop hasn't reached yet — kept as a running
        // count so the progress denominator can be recomputed in O(1).
        var pendingLeft = result.totalPending
        // The denominator for the progress bar: what this run will actually
        // deliver. With a per-run limit that's the limit, not the whole
        // backlog — a limited run of 100 reads "12 of 100", not "12 of 1051".
        var progressTotal = progressDenominator(
            imported: 0, failed: 0, pendingLeft: pendingLeft)
        callbacks.progress(0, progressTotal)

        var reimported: [ImportedEntry] = []

        for planned in plan {
            if cancelRequested {
                result.wasCancelled = true
                break
            }
            await waitWhilePaused()
            if cancelRequested {
                result.wasCancelled = true
                break
            }

            // The limit counts threads that actually reached Day One (imported
            // or failed) — not loop iterations, so already-imported threads
            // don't eat the budget on a second run.
            if let limit = config.maxThreadsToProcess,
               result.importedCount + result.failedCount >= limit {
                if pendingLeft > 0 {
                    log("Stopping after processing \(limit) threads.")
                    result.stoppedAtLimit = true
                }
                break
            }

            let outcome = await importSingleThread(
                planned.thread, processedIDs: &processedIDs, forceReimport: planned.isReimport
            )
            // Everything except an already-imported skip consumed one of the
            // pending threads counted in the denominator.
            if case .skippedAlreadyImported = outcome {} else {
                pendingLeft = max(0, pendingLeft - 1)
            }

            switch outcome {
            case .imported(var entry):
                result.importedCount += 1
                if planned.isReimport {
                    entry.previousTweetCount = ThreadSelection.countTweetsBefore(
                        planned.thread, startDate: config.startDate,
                        coveredThrough: config.lastCoveredThrough)
                    reimported.append(entry)
                }
            case .skippedAlreadyImported:
                result.skippedAlreadyImported += 1
            case .skippedNoJournal:
                result.skippedNoJournal += 1
            case .failed:
                result.failedCount += 1
            }

            if case .skippedAlreadyImported = outcome {} else {
                // A thread that produced no entry (no journal, or Day One
                // rejected it) shrinks the denominator so the bar can still
                // reach 100% — unless a limit means another thread simply
                // takes its place.
                progressTotal = progressDenominator(
                    imported: result.importedCount, failed: result.failedCount,
                    pendingLeft: pendingLeft)
                callbacks.progress(result.importedCount, progressTotal)
            }
        }

        // ---- Step 7: remind the user to delete re-imported duplicates -----
        if !reimported.isEmpty {
            result.reimportReport = ThreadSelection.formatReimportReport(
                reimported, username: config.currentUsername)
        }

        return result
    }

    /// What the progress bar counts up to: the entries already made plus
    /// however many more this run can still deliver — capped by whatever is
    /// left of the per-run limit, since the limit counts threads that reached
    /// Day One (imported or failed).
    private func progressDenominator(imported: Int, failed: Int, pendingLeft: Int) -> Int {
        guard let limit = config.maxThreadsToProcess else { return imported + pendingLeft }
        let budgetLeft = max(0, limit - imported - failed)
        return imported + min(pendingLeft, budgetLeft)
    }

    /// How many planned threads this run still has to import: a re-imported
    /// thread is pending until its extension marker is in the ledger, an
    /// ordinary one until its root tweet ID is.
    func countPendingImports(_ plan: [PlannedImport], processedIDs: Set<String>) -> Int {
        plan.filter { planned in
            let key = planned.isReimport
                ? ImportLedger.extensionMarker(planned.thread)
                : planned.thread[0].idStr
            return !processedIDs.contains(key)
        }.count
    }

    // MARK: - One thread → one entry (importer.py)

    /// What happened to one planned thread.
    enum ThreadOutcome {
        case imported(ImportedEntry)
        case skippedAlreadyImported
        /// Skipped by configuration (no reply journal, retweets ignored);
        /// recorded in the ledger so it isn't re-planned next run.
        case skippedNoJournal
        /// Day One rejected the entry; NOT recorded, so the next run retries.
        case failed
    }

    /// Imports one thread into Day One, unless the ledger says it's done.
    ///
    /// With forceReimport, the thread is imported even if it was imported
    /// before — used for threads that grew since their last import.
    private func importSingleThread(
        _ thread: TweetThread,
        processedIDs: inout Set<String>,
        forceReimport: Bool
    ) async -> ThreadOutcome {
        let firstTweet = thread[0]
        let tweetId = firstTweet.idStr

        if processedIDs.contains(tweetId), !forceReimport {
            return .skippedAlreadyImported
        }

        // A re-imported thread is tracked by "<root id>+<last tweet id>", so
        // running the same date range twice doesn't import the same extension
        // over and over.
        let reimportMarker = forceReimport ? ImportLedger.extensionMarker(thread) : nil
        if let marker = reimportMarker {
            if processedIDs.contains(marker) {
                log("Skipping thread \(tweetId): its extension was already imported.")
                return .skippedAlreadyImported
            }
            log("Re-importing thread \(tweetId): it was extended within the date range.")
        }

        // Step 5a: name the thread — this also strips RT prefixes from the
        // text, which is why the result is cached (see CategoryCache).
        let category: String
        if let cached = categoryCache.categories[tweetId] {
            category = cached
        } else {
            category = ThreadCategorizer.threadCategory(thread, context: context)
            categoryCache.categories[tweetId] = category
        }

        // Step 5b: compose the entry.
        let content = EntryComposer.aggregateThreadData(thread, config: config)
        if config.processTitlesWithLLM {
            callbacks.activity("Titling: \(String(firstTweet.fullText.prefix(80)))")
        }
        let title = await EntryComposer.generateEntryTitle(
            entryText: content.text,
            category: category,
            threadLength: thread.count,
            mediaFiles: content.mediaFiles,
            config: config
        ) { [ollama] text, media in
            guard let ollama else { return nil }
            return await ollama.generateTitle(entryText: text, mediaFiles: media)
        }
        guard let targetJournal = EntryComposer.targetJournal(
            category: category, tweetId: tweetId, config: config,
            log: { self.log($0) }
        ) else {
            // Mark as processed even if skipped
            recordProcessed(tweetId: tweetId, reimportMarker: reimportMarker,
                            processedIDs: &processedIDs)
            return .skippedNoJournal
        }

        // Step 6: hand the entry to the Day One CLI — as several entries when
        // the thread carries more attachments than Day One accepts in one.
        logEntryHeader(
            title: title,
            date: content.date ?? firstTweet.createdAt,
            attachments: content.mediaFiles.count
        )

        let parts = ThreadSplitter.split(thread)
        if parts.count > 1 {
            log("Thread \(tweetId) carries \(content.mediaFiles.count) attachments — "
                + "more than Day One's \(ThreadSplitter.maxAttachmentsPerEntry) per entry, "
                + "so it becomes \(parts.count) entries sharing the same date.")
        }
        for (index, part) in parts.enumerated() {
            let partTitle = index == 0 ? title : "\(title) (continued)"
            let partContent = parts.count == 1
                ? content : EntryComposer.aggregateThreadData(part, config: config)
            let entryText = EntryComposer.buildEntryContent(
                entryText: partContent.text, firstTweet: firstTweet, category: category,
                title: partTitle, config: config, isContinuation: index > 0
            )
            callbacks.activity("Saving to “\(targetJournal)”: \(partTitle)")
            let posted = dayOne.addPost(
                text: entryText,
                journal: targetJournal,
                tags: Array(Set(partContent.tags)),
                // Every part carries the thread's start date, so the parts sit
                // together in the journal.
                date: content.date,
                coordinate: partContent.coordinate,
                attachments: partContent.mediaFiles
            )
            guard posted else {
                if index > 0 {
                    log("The first \(index) part(s) of thread \(tweetId) were already "
                        + "saved — the retry will post them again; delete the extra copies.",
                        .warning)
                }
                log("Couldn't save thread \(tweetId) to Day One — it stays unrecorded, "
                    + "so the next run will retry it.", .error)
                callbacks.log("", .info)
                return .failed
            }
        }
        callbacks.log("", .info)

        recordProcessed(tweetId: tweetId, reimportMarker: reimportMarker,
                        processedIDs: &processedIDs)
        return .imported(ImportedEntry(
            tweetId: tweetId,
            title: title,
            category: category,
            journal: targetJournal,
            date: content.date ?? firstTweet.createdAt,
            tweetCount: thread.count
        ))
    }

    /// Writes to the ledger — unless this is a debug run, which must leave no
    /// trace so the listed threads import every time.
    private func recordProcessed(
        tweetId: String, reimportMarker: String?, processedIDs: inout Set<String>
    ) {
        guard config.debugTweetIDs.isEmpty else { return }
        do {
            try ledger.rememberProcessed(
                tweetId: tweetId, reimportMarker: reimportMarker, processedIDs: &processedIDs)
        } catch {
            // The entry is in Day One but its ledger line is not on disk, so a
            // future run will import it again. Keep the in-memory set right for
            // this run's bookkeeping, and make sure the user hears about it.
            processedIDs.insert(tweetId)
            if let reimportMarker { processedIDs.insert(reimportMarker) }
            log("Couldn't record thread \(tweetId) in the import ledger "
                + "(\(error.localizedDescription)) — the entry was created, but the next "
                + "run won't know and will import it again. Check \(ledger.fileURL.path)",
                .error)
        }
    }

    private static let entryDateFormatter = PipelineDates.formatter("dd MMMM yyyy, HH:mm")

    /// The block written to the log for one entry: what it is called, when the
    /// thread was posted, and how much media rides along. The Day One CLI adds
    /// its own "Success:" line right after, and the entry ends with a blank
    /// line — the tweet text itself stays out of the log.
    private func logEntryHeader(title: String, date: Date, attachments: Int) {
        callbacks.log("Title: \(title)", .thread)
        callbacks.log("Tweeted on: \(Self.entryDateFormatter.string(from: date))", .info)
        callbacks.log("Attachments: \(attachments)", .info)
    }

    // MARK: - Pause / cancel plumbing

    /// Cancellation comes through ImportControl (the app runs the engine on a
    /// detached task, which task cancellation can't reach); Task.isCancelled
    /// is honored too for callers that do run the engine as a child task.
    private var cancelRequested: Bool {
        control.isCancelled || Task.isCancelled
    }

    private func waitWhilePaused() async {
        guard control.isPaused else { return }
        callbacks.activity("Paused")
        while control.isPaused && !cancelRequested {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func log(_ message: String, _ kind: ImportLogKind = .info) {
        callbacks.log(message, kind)
    }
}
