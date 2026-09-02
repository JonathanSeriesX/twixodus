// Step 1 of the pipeline: find the Twitter archive and read every tweet.
//
// An unpacked Twitter archive is a folder named twitter-<YYYY-MM-DD>-<hash>.
// The tweets live in <archive>/data/ — in a single tweets.js, or split into
// tweets.js, tweets-part1.js, tweets-part2.js, ... when the archive is large.
// Threads regularly span that split, so every part is always loaded before
// threads are assembled.
//
// Two vintages of that data/ folder exist, and both are supported:
//
//   current (~2020 onwards)          older (2019 and before)
//   tweets.js, tweets-part<N>.js     tweet.js, tweet-part<N>.js
//   [ { "tweet" : { ... } }, ... ]   [ { ... }, ... ]   (no wrapper object)
//   tweets_media/                    tweet_media/
//
// The tweet objects themselves are the same in both: id_str, full_text,
// created_at, entities, in_reply_to_* — so once the wrapper and the file
// names are dealt with, the rest of the pipeline sees no difference.

import Foundation

public enum ArchiveError: LocalizedError {
    case notFound(searched: String)
    case unreadable(file: String, underlying: String)
    case malformed(file: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            return "Couldn't find data/tweets.js (or the older data/tweet.js) in \(searched). "
                + "Drop your Twitter archive (the .zip, or the unpacked folder)."
        case .unreadable(let file, let underlying):
            return "Couldn't read \(file): \(underlying)"
        case .malformed(let file, let detail):
            return "Couldn't parse \(file): \(detail) "
                + "The file may be corrupt or truncated — try re-extracting "
                + "or re-downloading the archive."
        }
    }
}

public enum TwitterArchiveLoader {

    // MARK: - Archive layouts

    /// One vintage of the data/ folder: what the tweet files and the media
    /// folder are called. Listed newest first, which is the order they are
    /// tried in when a folder is probed.
    struct Layout {
        let tweetsFile: String
        let partPattern: PyRegex
        let mediaFolder: String

        /// Current exports (~2020 onwards).
        static let current = Layout(
            tweetsFile: "tweets.js",
            partPattern: PyRegex(#"^tweets-part(\d+)\.js$"#),
            mediaFolder: "tweets_media")

        /// Older exports (2019 and before): singular names throughout.
        static let legacy = Layout(
            tweetsFile: "tweet.js",
            partPattern: PyRegex(#"^tweet-part(\d+)\.js$"#),
            mediaFolder: "tweet_media")

        static let all: [Layout] = [.current, .legacy]

        /// Which layout the given data/ folder follows, if any.
        static func detect(in dataFolder: URL) -> Layout? {
            let fm = FileManager.default
            return all.first { fm.fileExists(atPath: dataFolder.appendingPathComponent($0.tweetsFile).path) }
        }

        /// Whether the file is one of this layout's tweet parts.
        func isTweetsPart(_ url: URL) -> Bool {
            url.lastPathComponent == tweetsFile || partPattern.match(url.lastPathComponent) != nil
        }

        /// Sort key for archive parts: the main file is part 0, <name>-part<N>.js is part N.
        func partNumber(_ url: URL) -> Int {
            if let m = partPattern.match(url.lastPathComponent), let n = Int(m.group(1) ?? "") {
                return n
            }
            return 0
        }
    }

    // MARK: - Finding the archive

    /// Finds the archive at (or inside) the given folder.
    ///
    /// People drop all sorts of things, so three depths are tried, in order:
    ///
    ///   1. the dropped folder IS the data folder (it holds tweets.js or
    ///      tweet.js directly — someone dragged data/ out of the archive, or
    ///      an older export that was unpacked without the wrapper folder);
    ///   2. the dropped folder is the archive root (<dropped>/data/…);
    ///   3. the dropped folder holds one or more unpacked archives
    ///      (<dropped>/<anything>/data/…) — the newest wins: Twitter names the
    ///      folder twitter-<date>-<hash>, so the lexically largest name is the
    ///      latest export.
    public static func findArchive(at root: URL) throws -> TwitterArchiveRef {
        let fm = FileManager.default

        // (dataFolder, the unpacked archive as a whole, layout)
        var found: (dataFolder: URL, archiveRoot: URL, layout: Layout)?
        let direct = root.appendingPathComponent("data")
        if let layout = Layout.detect(in: root) {
            // A bare data folder: there is no archive around it, so the folder
            // itself stands in for the archive root.
            found = (root, root, layout)
        } else if let layout = Layout.detect(in: direct) {
            found = (direct, root, layout)
        } else {
            let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
                ?? []
            let candidates = children
                .compactMap { child -> (dataFolder: URL, archiveRoot: URL, layout: Layout)? in
                    let data = child.appendingPathComponent("data")
                    return Layout.detect(in: data).map { (data, child, $0) }
                }
            found = candidates.max { $0.archiveRoot.lastPathComponent < $1.archiveRoot.lastPathComponent }
        }

        guard let found else {
            throw ArchiveError.notFound(searched: root.path)
        }
        let (dataFolder, archiveRoot, layout) = found

        let all = (try? fm.contentsOfDirectory(at: dataFolder, includingPropertiesForKeys: nil)) ?? []
        let parts = all
            .filter(layout.isTweetsPart)
            .stableSorted { layout.partNumber($0) < layout.partNumber($1) }

        return TwitterArchiveRef(
            dataFolder: dataFolder,
            tweetsJSPaths: parts,
            mediaFolder: dataFolder.appendingPathComponent(layout.mediaFolder),
            archiveRoot: archiveRoot)
    }

    // MARK: - Loading the tweets

    /// Loads and combines tweets from every tweets*.js part of the archive.
    /// Returns the tweets plus the set of their IDs (the user's own tweets) —
    /// ThreadCategorizer reads that set to say "Quoted myself".
    public static func loadTweets(from archive: TwitterArchiveRef,
                                  log: (String) -> Void = { _ in }) throws -> (tweets: [Tweet], ownTweetIDs: Set<String>) {
        var tweets: [Tweet] = []
        for path in archive.tweetsJSPaths {
            tweets.append(contentsOf: try loadTweetsFromFile(path, log: log))
        }
        let ownIDs = Set(tweets.map(\.idStr))
        return (tweets, ownIDs)
    }

    /// The archive's date format: "Fri Mar 21 04:40:00 +0000 2006".
    private static let createdAtFormatter = PipelineDates.formatter("EEE MMM dd HH:mm:ss Z yyyy")

    /// Loads the tweets from one tweets*.js file.
    ///
    /// The file is JavaScript, not JSON: a `window.YTD.tweets.partN = ` prefix
    /// followed by a JSON array. Everything before the first '[' is cut off.
    ///
    /// Current archives wrap every tweet as `{"tweet": {...}}`; the older
    /// layout lists the tweet objects bare. Both are accepted, per item, so a
    /// tweet that lacks the wrapper is read as the tweet itself.
    ///
    /// An unparseable file throws instead of returning [] — a corrupt part
    /// would otherwise silently drop thousands of tweets from the import.
    /// Individually malformed tweets within a healthy file are skipped, with
    /// a warning saying how many.
    static func loadTweetsFromFile(_ url: URL, log: (String) -> Void = { _ in }) throws -> [Tweet] {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ArchiveError.unreadable(file: url.path, underlying: error.localizedDescription)
        }

        guard let start = content.firstIndex(of: "[") else {
            throw ArchiveError.malformed(
                file: url.lastPathComponent, detail: "no JSON array found in the file.")
        }

        let jsonData = Data(content[start...].utf8)
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw ArchiveError.malformed(
                file: url.lastPathComponent,
                detail: "JSON decoding failed (\(error.localizedDescription)).")
        }

        guard let items = parsed as? [[String: Any]] else {
            throw ArchiveError.malformed(
                file: url.lastPathComponent,
                detail: "unexpected JSON shape — expected an array of tweet objects.")
        }

        let tweets = items.compactMap { item -> Tweet? in
            let tweetDict = item["tweet"] as? [String: Any] ?? item
            return parseTweet(tweetDict)
        }
        if tweets.count != items.count {
            log("Warning: \(items.count - tweets.count) of \(items.count) tweets in "
                + "\(url.lastPathComponent) were malformed and were skipped.")
        }
        return tweets
    }

    private static func parseTweet(_ dict: [String: Any]) -> Tweet? {
        guard
            let idStr = dict["id_str"] as? String,
            let createdAtStr = dict["created_at"] as? String,
            let createdAt = createdAtFormatter.date(from: createdAtStr)
        else { return nil }

        let entities = dict["entities"] as? [String: Any] ?? [:]
        let extendedEntities = dict["extended_entities"] as? [String: Any]

        let urls = (entities["urls"] as? [[String: Any]] ?? []).map { u in
            URLEntity(
                url: u["url"] as? String,
                expandedURL: u["expanded_url"] as? String,
                displayURL: u["display_url"] as? String
            )
        }

        let hashtags = (entities["hashtags"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }

        let mentions = (entities["user_mentions"] as? [[String: Any]] ?? []).compactMap { m -> UserMention? in
            guard let screenName = m["screen_name"] as? String else { return nil }
            return UserMention(screenName: screenName, name: m["name"] as? String)
        }

        var coordinate: (latitude: Double, longitude: Double)?
        if let coords = dict["coordinates"] as? [String: Any],
           let pair = coords["coordinates"] as? [Any], pair.count >= 2,
           let longitude = asDouble(pair[0]), let latitude = asDouble(pair[1]) {
            coordinate = (latitude: latitude, longitude: longitude)
        }

        return Tweet(
            idStr: idStr,
            fullText: dict["full_text"] as? String ?? "",
            createdAt: createdAt,
            favoriteCount: asInt(dict["favorite_count"]) ?? 0,
            retweetCount: asInt(dict["retweet_count"]) ?? 0,
            source: dict["source"] as? String,
            inReplyToStatusIdStr: dict["in_reply_to_status_id_str"] as? String,
            inReplyToUserIdStr: dict["in_reply_to_user_id_str"] as? String,
            inReplyToScreenName: dict["in_reply_to_screen_name"] as? String,
            urls: urls,
            hashtags: hashtags,
            userMentions: mentions,
            entitiesMedia: parseMedia(entities["media"]),
            extendedMedia: extendedEntities.map { parseMedia($0["media"]) },
            coordinate: coordinate
        )
    }

    private static func parseMedia(_ raw: Any?) -> [MediaEntity] {
        (raw as? [[String: Any]] ?? []).map { m in
            let variants = ((m["video_info"] as? [String: Any])?["variants"] as? [[String: Any]] ?? [])
                .map { v in
                    VideoVariant(
                        contentType: v["content_type"] as? String,
                        bitrate: v["bitrate"] as? String,
                        url: v["url"] as? String
                    )
                }
            return MediaEntity(
                url: m["url"] as? String,
                type: m["type"] as? String,
                mediaURLHTTPS: m["media_url_https"] as? String,
                videoVariants: variants
            )
        }
    }

    private static func asInt(_ value: Any?) -> Int? {
        if let s = value as? String { return Int(s) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func asDouble(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    // MARK: - Account metadata

    public struct AccountInfo {
        public let accountId: String?
        public let username: String?
    }

    /// Reads the account ID and username from the archive's account.js. The ID
    /// is stable across username changes; returns nils if unavailable.
    public static func loadAccountInfo(from archive: TwitterArchiveRef) -> AccountInfo {
        guard let content = try? String(contentsOf: archive.accountJSPath, encoding: .utf8),
              let start = content.firstIndex(of: "["),
              let parsed = try? JSONSerialization.jsonObject(with: Data(content[start...].utf8)),
              let accounts = parsed as? [[String: Any]],
              let account = accounts.first?["account"] as? [String: Any]
        else {
            return AccountInfo(accountId: nil, username: nil)
        }
        return AccountInfo(
            accountId: account["accountId"] as? String,
            username: account["username"] as? String
        )
    }
}
