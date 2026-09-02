import XCTest

final class HydrationTests: XCTestCase {

    private var config = ImportConfig(
        journalName: "Tweets Test",
        replyJournalName: "Twitter Replies Test",
        currentUsername: "JonathanSeriesX",
        importOrder: .oldestFirst,
        processTitlesWithLLM: false
    )

    private func makeStore() -> HydrationStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("twitter-2026-01-15-\(UUID().uuidString)")
        return HydrationStore(archiveRoot: root)
    }

    private func okRecord(_ data: HydratedTweetData) -> HydrationRecord {
        HydrationRecord(status: HydrationRecord.statusOK, reason: nil, fetchedAt: Date(), tweet: data)
    }

    private func original(
        id: String = "999",
        screenName: String = "daken_",
        name: String? = "Arthur",
        createdAt: String? = "2017-11-17T22:53:57.000Z",
        text: String,
        urls: [HydratedURL] = [],
        media: [HydratedMediaFile] = []
    ) -> HydratedTweetData {
        HydratedTweetData(idStr: id, screenName: screenName, name: name,
                          createdAt: createdAt, text: text, urls: urls, media: media)
    }

    // MARK: - Store folder naming

    func testHydrationFolderNameForDatedArchive() {
        let url = HydrationStore.folderURL(
            for: URL(fileURLWithPath: "/x/twitter-2026-08-17-abcdef0123"))
        XCTAssertEqual(url.path, "/x/twitter-2026-08-17-hydration")
    }

    func testHydrationFolderNameForOtherFolders() {
        let url = HydrationStore.folderURL(for: URL(fileURLWithPath: "/x/my-archive"))
        XCTAssertEqual(url.path, "/x/my-archive-hydration")
    }

    // MARK: - Truncation detection

    func testTruncationDetection() {
        XCTAssertTrue(ArchiveLoading.looksTruncated("RT @a: cut here…"))
        XCTAssertTrue(ArchiveLoading.looksTruncated("RT @a: cut https://t.co/abc…"))
        XCTAssertTrue(ArchiveLoading.looksTruncated("RT @a: old style..."))
        XCTAssertFalse(ArchiveLoading.looksTruncated("RT @a: complete tweet"))
    }

    // MARK: - Planner

    func testPlannerSplitsPendingFromDone() {
        let store = makeStore()
        let pending = Fixtures.tweet(id: "1", text: "RT @a: cut…")
        pending.isRetweet = true
        pending.isTruncatedRetweet = true
        let done = Fixtures.tweet(id: "2", text: "RT @b: cut…")
        done.isRetweet = true
        done.isTruncatedRetweet = true
        store.retweets["2"] = okRecord(original(text: "full"))

        let plan = HydrationPlanner.plan(
            tweets: [pending, done], ownTweetIDs: ["1", "2"],
            archiveUsername: "me", store: store)
        XCTAssertEqual(plan.pendingRetweets.map(\.idStr), ["1"])
        XCTAssertEqual(plan.retweetsDone, 1)
    }

    func testPlannerFindsQuotesAndSkipsOwnAndRetweets() {
        let store = makeStore()
        let quoteURL = URLEntity(
            url: "https://t.co/q1",
            expandedURL: "https://x.com/somebody/status/555",
            displayURL: "x.com/somebody/s…")
        let quote = Fixtures.tweet(id: "1", text: "comment", urls: [quoteURL])
        let sameQuote = Fixtures.tweet(id: "2", text: "again", urls: [quoteURL])
        let selfQuote = Fixtures.tweet(id: "3", text: "mine", urls: [URLEntity(
            url: "https://t.co/q2",
            expandedURL: "https://x.com/whoever/status/42",
            displayURL: nil)])
        let retweetWithLink = Fixtures.tweet(id: "4", text: "RT @a: look", urls: [quoteURL])
        retweetWithLink.isRetweet = true

        let plan = HydrationPlanner.plan(
            tweets: [quote, sameQuote, selfQuote, retweetWithLink],
            ownTweetIDs: ["1", "2", "3", "4", "42"],
            archiveUsername: "me", store: store)
        // The two tweets quoting 555 collapse into one fetch; the self-quote
        // (id 42 is in the archive) and the retweet's link are skipped.
        XCTAssertEqual(plan.pendingQuotes.map(\.statusId), ["555"])
    }

    func testPlannerFindsMissingMediaSource() {
        let store = makeStore()
        let video = MediaEntity(
            url: "https://t.co/v", type: "video", mediaURLHTTPS: nil,
            videoVariants: [
                VideoVariant(contentType: "video/mp4", bitrate: "832000",
                             url: "https://video.twimg.com/ext_tw_video/1/pu/vid/640x360/low.mp4"),
                VideoVariant(contentType: "video/mp4", bitrate: "2176000",
                             url: "https://video.twimg.com/ext_tw_video/1/pu/vid/1280x720/high.mp4?tag=1"),
            ])
        let tweet = Fixtures.tweet(id: "7", text: "clip", extendedMedia: [video])
        tweet.mediaFiles = ["/nonexistent/tweets_media/7-high.mp4"]

        let plan = HydrationPlanner.plan(
            tweets: [tweet], ownTweetIDs: ["7"], archiveUsername: nil, store: store)
        XCTAssertEqual(plan.pendingMedia.count, 1)
        XCTAssertEqual(plan.pendingMedia[0].fileName, "7-high.mp4")
        XCTAssertEqual(plan.pendingMedia[0].sourceURL,
                       "https://video.twimg.com/ext_tw_video/1/pu/vid/1280x720/high.mp4?tag=1")
    }

    // MARK: - Overlay

    func testOverlayRebuildsTruncatedRetweet() {
        let store = makeStore()
        let tweet = Fixtures.tweet(id: "1", text: "RT @daken_: cut off here…")
        tweet.isRetweet = true
        tweet.isTruncatedRetweet = true
        store.retweets["1"] = okRecord(original(
            text: "the full text with a link https://t.co/abc",
            urls: [HydratedURL(tco: "https://t.co/abc",
                               expanded: "https://example.com/page",
                               display: "example.com/page")]))

        HydrationOverlay.apply(tweets: [tweet], store: store)
        XCTAssertEqual(
            tweet.fullText,
            "RT @daken_: the full text with a link [example.com/page](https://example.com/page)")
    }

    func testOverlayOmitsPrefixWhenAlreadyStripped() {
        // Categorization strips "RT @user:" in place; a later overlay run must
        // not bring it back.
        let store = makeStore()
        let tweet = Fixtures.tweet(id: "1", text: "cut off here…")
        tweet.isRetweet = true
        tweet.isTruncatedRetweet = true
        store.retweets["1"] = okRecord(original(text: "the full text"))

        HydrationOverlay.apply(tweets: [tweet], store: store)
        XCTAssertEqual(tweet.fullText, "the full text")
    }

    func testOverlayAttachesQuoteAndStripsTrailingLink() {
        let store = makeStore()
        let tweet = Fixtures.tweet(
            id: "1",
            text: "Ребят, научите [x.com/unusual_whales…](https://x.com/unusual_whales/status/555)",
            urls: [URLEntity(url: "https://t.co/q",
                             expandedURL: "https://x.com/unusual_whales/status/555",
                             displayURL: "x.com/unusual_whales…")])
        store.quotes["555"] = okRecord(original(
            id: "555", screenName: "unusual_whales", name: "unusual_whales",
            createdAt: "2026-01-12T15:00:00.000Z",
            text: "\"Gen Z has cut down on their effort at work,\" per YF."))

        HydrationOverlay.apply(tweets: [tweet], store: store)
        XCTAssertEqual(tweet.fullText, "Ребят, научите")
        XCTAssertEqual(tweet.hydratedQuote?.name, "unusual_whales")
        XCTAssertEqual(tweet.hydratedQuote?.statusId, "555")
    }

    func testOverlayKeepsMidTextLink() {
        let store = makeStore()
        let tweet = Fixtures.tweet(
            id: "1",
            text: "see [x.com/a/status/555](https://x.com/a/status/555) which is wild",
            urls: [URLEntity(url: "https://t.co/q",
                             expandedURL: "https://x.com/a/status/555",
                             displayURL: nil)])
        store.quotes["555"] = okRecord(original(id: "555", screenName: "a", text: "quoted"))

        HydrationOverlay.apply(tweets: [tweet], store: store)
        XCTAssertTrue(tweet.fullText.contains("which is wild"))
        XCTAssertTrue(tweet.fullText.contains("x.com/a/status/555"))
        XCTAssertNotNil(tweet.hydratedQuote)
    }

    // MARK: - The blockquote in the entry

    func testQuoteBlockFormat() {
        let quote = HydratedQuote(
            statusId: "555", screenName: "unusual_whales", name: "unusual_whales",
            createdAt: PipelineDates.date(2026, 1, 12, 15, 0, 0),
            text: "\"Gen Z has cut down on their effort at work,\" per YF.")
        let block = EntryComposer.quoteBlock(
            quote, quotingDate: PipelineDates.date(2026, 1, 14))
        let marker = EntryComposer.blockquoteMarker
        XCTAssertEqual(block, marker
            + "Quoting [unusual_whales from Jan 12](https://twitter.com/unusual_whales/status/555):\n"
            + marker
            + "\"Gen Z has cut down on their effort at work,\" per YF.")
    }

    func testQuoteBlockAddsYearWhenDifferent() {
        let quote = HydratedQuote(
            statusId: "5", screenName: "a", name: "Somebody",
            createdAt: PipelineDates.date(2013, 5, 1), text: "old wisdom")
        let block = EntryComposer.quoteBlock(
            quote, quotingDate: PipelineDates.date(2026, 1, 14))
        XCTAssertTrue(block.contains("Somebody from May 1, 2013"))
    }

    func testQuoteBlockSurvivesMarkdownEscaping() {
        let tweet = Fixtures.tweet(id: "1", text: "my comment")
        tweet.hydratedQuote = HydratedQuote(
            statusId: "555", screenName: "a", name: "Somebody",
            createdAt: nil, text: "quoted line")
        let content = EntryComposer.aggregateThreadData([tweet], config: config)
        let entry = EntryComposer.buildEntryContent(
            entryText: content.text, firstTweet: tweet, category: "Quoted @a",
            title: "Quoted @a", config: config, isContinuation: false)
        // The injected blockquote renders as a real one...
        XCTAssertTrue(entry.contains("> Quoting [Somebody](https://twitter.com/a/status/555):"))
        XCTAssertTrue(entry.contains("> quoted line"))
        // ...while a ">" typed in tweet text stays escaped (see escapeMarkdown).
        XCTAssertFalse(entry.contains(EntryComposer.blockquoteMarker))
    }

    // MARK: - Retryable records

    private func truncatedRetweet(id: String) -> Tweet {
        let tweet = Fixtures.tweet(id: id, text: "RT @a: cut…")
        tweet.isRetweet = true
        tweet.isTruncatedRetweet = true
        return tweet
    }

    private func withMedia(_ data: HydratedTweetData, fileName: String?) -> HydratedTweetData {
        var copy = data
        copy.media = [HydratedMediaFile(
            tco: "https://t.co/m", type: "photo",
            sourceURL: "https://pbs.twimg.com/media/x.jpg?name=orig", fileName: fileName)]
        return copy
    }

    func testRecordWithUndownloadedMediaIsNotComplete() {
        let downloaded = okRecord(withMedia(original(text: "hi"), fileName: "1-x.jpg"))
        let failed = okRecord(withMedia(original(text: "hi"), fileName: nil))
        XCTAssertTrue(downloaded.isComplete)
        XCTAssertTrue(failed.isOK, "the text is still worth keeping")
        XCTAssertFalse(failed.isComplete, "but the attachment is still owed")
        XCTAssertEqual(failed.missingMediaCount, 1)
    }

    func testHalfDownloadedRetweetIsRetryableNotDone() {
        let store = makeStore()
        let tweet = truncatedRetweet(id: "1")
        store.retweets["1"] = okRecord(withMedia(original(text: "full"), fileName: nil))

        let scan = HydrationPlanner.plan(
            tweets: [tweet], ownTweetIDs: ["1"], archiveUsername: nil, store: store)
        XCTAssertEqual(scan.retweetsDone, 0)
        XCTAssertEqual(scan.retweetsIncomplete, 1)
        XCTAssertEqual(scan.totalPending, 0, "a normal scan leaves it alone")
        XCTAssertEqual(scan.totalRetryable, 1)

        let retry = HydrationPlanner.plan(
            tweets: [tweet], ownTweetIDs: ["1"], archiveUsername: nil,
            store: store, retrying: true)
        XCTAssertEqual(retry.pendingRetweets.map(\.idStr), ["1"])
    }

    func testUnavailableRecordsAreOnlyPlannedWhenRetrying() {
        let store = makeStore()
        let tweet = truncatedRetweet(id: "1")
        store.retweets["1"] = HydrationRecord(
            status: HydrationRecord.statusUnavailable,
            reason: "Not found (HTTP 404) — deleted, or the endpoint declined",
            fetchedAt: Date(), tweet: nil)
        let quoter = Fixtures.tweet(id: "2", text: "look", urls: [URLEntity(
            url: "https://t.co/q", expandedURL: "https://x.com/a/status/555", displayURL: nil)])
        store.quotes["555"] = HydrationRecord(
            status: HydrationRecord.statusUnavailable, reason: "suspended",
            fetchedAt: Date(), tweet: nil)

        let scan = HydrationPlanner.plan(
            tweets: [tweet, quoter], ownTweetIDs: ["1", "2"], archiveUsername: nil, store: store)
        XCTAssertEqual(scan.totalPending, 0)
        XCTAssertEqual(scan.retweetsUnavailable, 1)
        XCTAssertEqual(scan.quotesUnavailable, 1)
        XCTAssertEqual(scan.totalRetryable, 2)

        let retry = HydrationPlanner.plan(
            tweets: [tweet, quoter], ownTweetIDs: ["1", "2"], archiveUsername: nil,
            store: store, retrying: true)
        XCTAssertEqual(retry.pendingRetweets.map(\.idStr), ["1"])
        XCTAssertEqual(retry.pendingQuotes.map(\.statusId), ["555"])
    }

    func testRetryingLeavesFinishedRecordsAlone() {
        let store = makeStore()
        let tweet = truncatedRetweet(id: "1")
        store.retweets["1"] = okRecord(withMedia(original(text: "full"), fileName: "1-x.jpg"))

        let retry = HydrationPlanner.plan(
            tweets: [tweet], ownTweetIDs: ["1"], archiveUsername: nil,
            store: store, retrying: true)
        XCTAssertEqual(retry.totalPending, 0)
        XCTAssertEqual(retry.retweetsDone, 1)
    }

    // MARK: - Scoping the scan to what the run will import

    private func threadsForRun(
        _ threads: [TweetThread], config: ImportConfig, processedIDs: Set<String> = []
    ) -> [TweetThread] {
        let plan = ThreadSelection.planRun(threads, config: config, processedIDs: processedIDs)
        return ThreadSelection.threadsThisRunWillImport(
            plan.imports, processedIDs: processedIDs, limit: config.maxThreadsToProcess)
    }

    func testRunSelectionHonorsTheLedger() {
        let threads = ["1", "2", "3"].map { [Fixtures.tweet(id: $0)] }
        let picked = threadsForRun(threads, config: ImportConfig(), processedIDs: ["1", "2"])
        XCTAssertEqual(picked.map { $0[0].idStr }, ["3"])
    }

    func testRunSelectionHonorsTheLimitAndOrder() {
        let threads = (1...5).map {
            [Fixtures.tweet(id: "\($0)", createdAt: PipelineDates.date(2020, 1, $0))]
        }
        var oldest = ImportConfig(maxThreadsToProcess: 2, importOrder: .oldestFirst)
        XCTAssertEqual(threadsForRun(threads, config: oldest).map { $0[0].idStr }, ["1", "2"])

        oldest.importOrder = .newestFirst
        XCTAssertEqual(threadsForRun(threads, config: oldest).map { $0[0].idStr }, ["5", "4"])

        oldest.importOrder = .random
        let first = threadsForRun(threads, config: oldest).map { $0[0].idStr }
        let second = threadsForRun(threads, config: oldest).map { $0[0].idStr }
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first, second, "a seeded shuffle, so Retrieve and Import pick the same threads")
    }

    func testRunSelectionHonorsTheDateRange() {
        let threads = [
            [Fixtures.tweet(id: "old", createdAt: PipelineDates.date(2019, 6, 1))],
            [Fixtures.tweet(id: "new", createdAt: PipelineDates.date(2021, 6, 1))],
        ]
        let config = ImportConfig(
            startDate: PipelineDates.date(2021, 1, 1), endDate: PipelineDates.date(2022, 1, 1))
        XCTAssertEqual(threadsForRun(threads, config: config).map { $0[0].idStr }, ["new"])
    }

    func testConfigSkipsMatchTheJournalRules() {
        let retweet = [Fixtures.tweet(id: "1", text: "RT @a: hello")]
        let reply = [Fixtures.tweet(id: "2", text: "@bob sure", replyToStatus: "9",
                                    replyToScreenName: "bob")]
        let plain = [Fixtures.tweet(id: "3", text: "hello")]

        var config = ImportConfig(replyJournalName: "Replies", ignoreRetweets: false)
        for thread in [retweet, reply, plain] {
            XCTAssertFalse(ThreadCategorizer.isSkippedByConfig(thread, config: config))
        }

        config.ignoreRetweets = true
        config.replyJournalName = nil
        XCTAssertTrue(ThreadCategorizer.isSkippedByConfig(retweet, config: config))
        XCTAssertTrue(ThreadCategorizer.isSkippedByConfig(reply, config: config))
        XCTAssertFalse(ThreadCategorizer.isSkippedByConfig(plain, config: config))
    }

    func testKindAgreesWithTheCategoryItProduces() {
        // kind() decides the journal without touching the thread; the category
        // it leads to must match. (threadCategory mutates, so kind runs first.)
        let context = ThreadCategorizer.Context(ownTweetIDs: [], currentUsername: "me")
        let cases: [(TweetThread, ThreadCategorizer.ThreadKind, String)] = [
            ([Fixtures.tweet(id: "1", text: "RT @a: hi")], .retweet, "Retweeted "),
            ([Fixtures.tweet(id: "2", text: "look", urls: [URLEntity(
                url: "https://t.co/x", expandedURL: "https://x.com/a/status/5",
                displayURL: nil)])], .quote, "Quoted "),
            ([Fixtures.tweet(id: "3", text: "@bob sure", replyToStatus: "9",
                             replyToScreenName: "bob")], .reply, "Replied to "),
            ([Fixtures.tweet(id: "4", text: "just a tweet")], .own, "Tweeted"),
        ]
        for (thread, expectedKind, expectedPrefix) in cases {
            XCTAssertEqual(ThreadCategorizer.kind(thread), expectedKind)
            XCTAssertTrue(
                ThreadCategorizer.threadCategory(thread, context: context).hasPrefix(expectedPrefix),
                "kind \(expectedKind) should lead to a “\(expectedPrefix)…” category")
        }
    }

    // MARK: - Store round-trip

    func testStoreRoundTrip() throws {
        let store = makeStore()
        store.retweets["1"] = okRecord(original(text: "hello"))
        store.quotes["2"] = HydrationRecord(
            status: HydrationRecord.statusUnavailable, reason: "suspended",
            fetchedAt: Date(), tweet: nil)
        try store.save()
        defer { try? FileManager.default.removeItem(at: store.folder) }

        let reloaded = HydrationStore(archiveRoot: store.folder
            .deletingLastPathComponent()
            .appendingPathComponent("twitter-2026-01-15-whatever"))
        XCTAssertEqual(reloaded.folder.path, store.folder.path)
        XCTAssertTrue(reloaded.exists)
        reloaded.load()
        XCTAssertEqual(reloaded.retweets["1"]?.tweet?.text, "hello")
        XCTAssertEqual(reloaded.quotes["2"]?.reason, "suspended")
        XCTAssertFalse(reloaded.quotes["2"]!.isOK)
    }

    // MARK: - Syndication token

    func testTokenDerivation() {
        // The widget's JS: ((id / 1e15) * Math.PI).toString(36)
        //                       .replace(/(0+|\.)/g, '')
        let token = SyndicationClient.token(for: "1899882561553207629")
        XCTAssertEqual(token, "4lsnnlkevnz4k")
        XCTAssertFalse(token.contains("0"))
        XCTAssertFalse(token.contains("."))
        // Deterministic: same id, same token.
        XCTAssertEqual(token, SyndicationClient.token(for: "1899882561553207629"))
    }
}
