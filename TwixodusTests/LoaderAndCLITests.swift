import XCTest

final class TwitterArchiveLoaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("twixodus-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeArchive(named name: String, parts: [String: String]) throws -> URL {
        let data = tempDir.appendingPathComponent("\(name)/data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        for (file, content) in parts {
            try content.write(to: data.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return tempDir.appendingPathComponent(name)
    }

    private let sampleTweetJS = """
        window.YTD.tweets.part0 = [
          {
            "tweet" : {
              "id_str" : "123",
              "full_text" : "hello world",
              "created_at" : "Fri Mar 21 04:40:00 +0000 2006",
              "favorite_count" : "5",
              "retweet_count" : "2",
              "source" : "web",
              "entities" : { "hashtags" : [ { "text" : "hi" } ], "urls" : [ ], "user_mentions" : [ ] }
            }
          }
        ]
        """

    // MARK: Older archive layout (tweet.js, bare tweet objects, tweet_media/)

    /// The 2019-and-earlier layout: singular file name, and each tweet object
    /// sits directly in the array with no {"tweet": …} wrapper around it.
    private let legacyTweetJS = """
        window.YTD.tweet.part0 = [ {
          "retweeted" : false,
          "source" : "web",
          "entities" : { "hashtags" : [ { "text" : "hi" } ], "urls" : [ ], "user_mentions" : [ ] },
          "favorite_count" : "5",
          "id_str" : "123",
          "retweet_count" : "2",
          "id" : "123",
          "created_at" : "Fri Mar 21 04:40:00 +0000 2006",
          "full_text" : "hello world"
        } ]
        """

    func testFindsLegacyArchiveWithSingularTweetJS() throws {
        let root = try makeArchive(named: "twitter-2019-12-31-abc", parts: ["tweet.js": legacyTweetJS])
        let archive = try TwitterArchiveLoader.findArchive(at: root)
        XCTAssertEqual(archive.tweetsJSPaths.map(\.lastPathComponent), ["tweet.js"])
        XCTAssertEqual(archive.mediaFolder.lastPathComponent, "tweet_media")
    }

    func testLegacyArchiveFoundInsideContainerFolderAndByAnyName() throws {
        // The user's folder need not be called twitter-*: a bare data/ inside
        // whatever they dropped is enough.
        let root = try makeArchive(named: "some-renamed-export", parts: ["tweet.js": legacyTweetJS])
        let archive = try TwitterArchiveLoader.findArchive(at: root)
        XCTAssertEqual(archive.tweetsJSPaths.map(\.lastPathComponent), ["tweet.js"])

        // And a twitter-* folder in the legacy layout is found from its parent too.
        _ = try makeArchive(named: "twitter-2019-12-31-abc", parts: ["tweet.js": legacyTweetJS])
        let container = tempDir.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: tempDir.appendingPathComponent("twitter-2019-12-31-abc"),
            to: container.appendingPathComponent("twitter-2019-12-31-abc"))
        let fromContainer = try TwitterArchiveLoader.findArchive(at: container)
        XCTAssertEqual(fromContainer.dataFolder.deletingLastPathComponent().lastPathComponent,
                       "twitter-2019-12-31-abc")
    }

    func testDataFolderItselfCanBeDropped() throws {
        // The reporter dragged the bare data/ folder in — no archive root
        // around it. Both layouts must be found at that depth.
        let legacyRoot = try makeArchive(named: "old", parts: ["tweet.js": legacyTweetJS])
        let legacy = try TwitterArchiveLoader.findArchive(at: legacyRoot.appendingPathComponent("data"))
        XCTAssertEqual(legacy.tweetsJSPaths.map(\.lastPathComponent), ["tweet.js"])
        XCTAssertEqual(legacy.dataFolder.lastPathComponent, "data")
        XCTAssertEqual(legacy.mediaFolder.lastPathComponent, "tweet_media")

        let currentRoot = try makeArchive(named: "new", parts: ["tweets.js": sampleTweetJS])
        let current = try TwitterArchiveLoader.findArchive(at: currentRoot.appendingPathComponent("data"))
        XCTAssertEqual(current.tweetsJSPaths.map(\.lastPathComponent), ["tweets.js"])
        XCTAssertEqual(current.mediaFolder.lastPathComponent, "tweets_media")
    }

    func testBareDataFolderDropKeepsHydrationCacheBesideIt() throws {
        // Dropping <somewhere>/data directly: the archive root is that folder,
        // so the hydration cache goes to <somewhere>/data-hydration — not next
        // to <somewhere> itself.
        let root = try makeArchive(named: "somewhere", parts: ["tweet.js": legacyTweetJS])
        let data = root.appendingPathComponent("data")
        let archive = try TwitterArchiveLoader.findArchive(at: data)
        XCTAssertEqual(archive.archiveRoot, data)
        XCTAssertEqual(HydrationStore(for: archive).folder, root.appendingPathComponent("data-hydration"))

        // Whereas the usual drop of the archive root keeps the old placement.
        let usual = try TwitterArchiveLoader.findArchive(at: root)
        XCTAssertEqual(usual.archiveRoot, root)
        XCTAssertEqual(HydrationStore(for: usual).folder, tempDir.appendingPathComponent("somewhere-hydration"))
    }

    func testDataFolderNeedNotBeCalledData() throws {
        // A folder holding tweet.js directly counts, whatever it is called.
        let folder = tempDir.appendingPathComponent("my-old-tweets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try legacyTweetJS.write(to: folder.appendingPathComponent("tweet.js"), atomically: true, encoding: .utf8)
        let archive = try TwitterArchiveLoader.findArchive(at: folder)
        XCTAssertEqual(archive.dataFolder, folder)
        XCTAssertEqual(archive.tweetsJSPaths.map(\.lastPathComponent), ["tweet.js"])
    }

    func testArchiveInsideArbitrarilyNamedSubfolderIsFound() throws {
        // <dropped>/<renamed export>/data/tweet.js — the subfolder no longer
        // starts with twitter-, which must not matter.
        _ = try makeArchive(named: "archive-from-matthew", parts: ["tweet.js": legacyTweetJS])
        let archive = try TwitterArchiveLoader.findArchive(at: tempDir)
        XCTAssertEqual(archive.dataFolder.deletingLastPathComponent().lastPathComponent, "archive-from-matthew")
    }

    func testLegacyMultiPartArchiveLoadedInOrder() throws {
        let root = try makeArchive(named: "twitter-2019-12-31-abc", parts: [
            "tweet.js": legacyTweetJS,
            "tweet-part2.js": legacyTweetJS.replacingOccurrences(of: "\"123\"", with: "\"789\""),
            "tweet-part1.js": legacyTweetJS.replacingOccurrences(of: "\"123\"", with: "\"456\""),
        ])
        let archive = try TwitterArchiveLoader.findArchive(at: root)
        XCTAssertEqual(archive.tweetsJSPaths.map(\.lastPathComponent),
                       ["tweet.js", "tweet-part1.js", "tweet-part2.js"])
        let (tweets, _) = try TwitterArchiveLoader.loadTweets(from: archive)
        XCTAssertEqual(tweets.map(\.idStr), ["123", "456", "789"])
    }

    func testLegacyBareTweetObjectsParsed() throws {
        let root = try makeArchive(named: "twitter-2019-12-31-abc", parts: ["tweet.js": legacyTweetJS])
        let archive = try TwitterArchiveLoader.findArchive(at: root)
        var warnings: [String] = []
        let (tweets, ownIDs) = try TwitterArchiveLoader.loadTweets(from: archive) { warnings.append($0) }
        XCTAssertEqual(tweets.count, 1)
        XCTAssertTrue(warnings.isEmpty, "a healthy legacy file must not report malformed tweets")
        let tweet = tweets[0]
        XCTAssertEqual(tweet.idStr, "123")
        XCTAssertEqual(tweet.fullText, "hello world")
        XCTAssertEqual(tweet.favoriteCount, 5)
        XCTAssertEqual(tweet.retweetCount, 2)
        XCTAssertEqual(tweet.hashtags, ["hi"])
        XCTAssertEqual(ownIDs, ["123"])
    }

    func testCurrentLayoutWinsWhenBothTweetFilesExist() throws {
        // Belt and braces: if a folder somehow holds both names, the current
        // layout is authoritative and the singular file is ignored.
        let root = try makeArchive(named: "twitter-2026-01-15-abc",
                                   parts: ["tweets.js": sampleTweetJS, "tweet.js": legacyTweetJS])
        let archive = try TwitterArchiveLoader.findArchive(at: root)
        XCTAssertEqual(archive.tweetsJSPaths.map(\.lastPathComponent), ["tweets.js"])
        XCTAssertEqual(archive.mediaFolder.lastPathComponent, "tweets_media")
    }

    func testCurrentArchiveResolvesPluralMediaFolder() throws {
        let root = try makeArchive(named: "twitter-2026-01-15-abc", parts: ["tweets.js": sampleTweetJS])
        let archive = try TwitterArchiveLoader.findArchive(at: root)
        XCTAssertEqual(archive.mediaFolder, archive.dataFolder.appendingPathComponent("tweets_media"))
    }

    // MARK: Current archive layout

    func testFindsArchiveWhenFolderIsArchiveRoot() throws {
        let root = try makeArchive(named: "twitter-2026-01-15-abc", parts: ["tweets.js": sampleTweetJS])
        let archive = try TwitterArchiveLoader.findArchive(at: root)
        XCTAssertEqual(archive.tweetsJSPaths.map(\.lastPathComponent), ["tweets.js"])
    }

    func testFindsNewestArchiveInsideContainerFolder() throws {
        _ = try makeArchive(named: "twitter-2024-01-01-old", parts: ["tweets.js": sampleTweetJS])
        _ = try makeArchive(named: "twitter-2026-01-15-new", parts: ["tweets.js": sampleTweetJS])
        let archive = try TwitterArchiveLoader.findArchive(at: tempDir)
        XCTAssertTrue(archive.dataFolder.path.contains("twitter-2026-01-15-new"))
    }

    func testMultiPartArchiveLoadedInOrder() throws {
        let root = try makeArchive(named: "twitter-2026-01-15-abc", parts: [
            "tweets.js": sampleTweetJS,
            "tweets-part1.js": sampleTweetJS.replacingOccurrences(of: "123", with: "456"),
            "tweets-part2.js": sampleTweetJS.replacingOccurrences(of: "123", with: "789"),
        ])
        let archive = try TwitterArchiveLoader.findArchive(at: root)
        XCTAssertEqual(
            archive.tweetsJSPaths.map(\.lastPathComponent),
            ["tweets.js", "tweets-part1.js", "tweets-part2.js"])

        let (tweets, ownIDs) = try TwitterArchiveLoader.loadTweets(from: archive)
        XCTAssertEqual(tweets.map(\.idStr), ["123", "456", "789"])
        XCTAssertEqual(ownIDs, ["123", "456", "789"])
    }

    func testMissingArchiveThrows() {
        XCTAssertThrowsError(try TwitterArchiveLoader.findArchive(at: tempDir))
    }

    func testTweetFieldsParsed() throws {
        let root = try makeArchive(named: "twitter-2026-01-15-abc", parts: ["tweets.js": sampleTweetJS])
        let archive = try TwitterArchiveLoader.findArchive(at: root)
        let (tweets, _) = try TwitterArchiveLoader.loadTweets(from: archive)

        let tweet = try XCTUnwrap(tweets.first)
        XCTAssertEqual(tweet.fullText, "hello world")
        XCTAssertEqual(tweet.createdAt, PipelineDates.date(2006, 3, 21, 4, 40, 0))
        XCTAssertEqual(tweet.favoriteCount, 5)
        XCTAssertEqual(tweet.retweetCount, 2)
        XCTAssertEqual(tweet.hashtags, ["hi"])
        XCTAssertNil(tweet.extendedMedia)
    }

    func testAccountInfoParsed() throws {
        let accountJS = """
            window.YTD.account.part0 = [
              {
                "account" : {
                  "email" : "x@example.com",
                  "createdVia" : "web",
                  "username" : "JonathanSeriesX",
                  "accountId" : "381554576",
                  "createdAt" : "2011-09-27T17:29:22.000Z",
                  "accountDisplayName" : "Jonathan"
                }
              }
            ]
            """
        let root = try makeArchive(named: "twitter-2026-01-15-abc",
                                   parts: ["tweets.js": sampleTweetJS, "account.js": accountJS])
        let archive = try TwitterArchiveLoader.findArchive(at: root)
        let info = TwitterArchiveLoader.loadAccountInfo(from: archive)
        XCTAssertEqual(info.accountId, "381554576")
        XCTAssertEqual(info.username, "JonathanSeriesX")
    }
}

final class DayOneCLITests: XCTestCase {

    func testCommandOrderIsOptionsFirstThenNew() {
        let cli = DayOneCLI(binaryPath: "/usr/local/bin/dayone")
        let command = cli.buildCommand(
            text: "entry text",
            journal: "Tweets",
            tags: ["f1", "quali"],
            date: PipelineDates.date(2020, 5, 17, 9, 30, 0),
            coordinate: (latitude: 51.5, longitude: -0.12),
            attachments: ["/tmp/a.jpg", "/tmp/b.mp4"]
        )
        XCTAssertEqual(command, [
            "--journal", "Tweets",
            "--date", "2020-05-17 09:30:00",
            "-z", "UTC",
            "--coordinate", "51.5", "-0.12",
            "--tags", "f1", "quali",
            "--attachments", "/tmp/a.jpg", "/tmp/b.mp4",
            "--", "new", "entry text",
        ])
    }

    func testMinimalCommand() {
        let cli = DayOneCLI(binaryPath: "/usr/local/bin/dayone")
        XCTAssertEqual(
            cli.buildCommand(text: "hi", journal: nil, tags: [], date: nil,
                             coordinate: nil, attachments: []),
            ["--", "new", "hi"])
    }
}

final class OllamaNormalizeTests: XCTestCase {

    func testStripsQuotesAndTrailingPeriod() {
        XCTAssertEqual(OllamaClient.normalizeTitle("\u{201C}Wrote about Formula 1.\u{201D}"),
                       "Wrote about Formula 1")
    }

    func testDeclinedTitleGivesNil() {
        XCTAssertNil(OllamaClient.normalizeTitle("Tweeted"))
        XCTAssertNil(OllamaClient.normalizeTitle(" tweeted. "))
        XCTAssertNil(OllamaClient.normalizeTitle(""))
    }

    func testRamblingTitlesRejected() {
        XCTAssertNil(OllamaClient.normalizeTitle(String(repeating: "long ", count: 20)))
        XCTAssertNil(OllamaClient.normalizeTitle("one two three four five six seven eight nine ten eleven"))
    }

    func testFirstLineOnlyAndCapitalized() {
        XCTAssertEqual(OllamaClient.normalizeTitle("wrote about cars\nand some rambling"),
                       "Wrote about cars")
    }
}
