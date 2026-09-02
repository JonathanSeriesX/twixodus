// The Retrieve step's on-disk cache: everything fetched from Twitter's
// syndication endpoint (see SyndicationClient), stored NEXT TO the archive so
// the original export is never touched. For twitter-2026-08-17-<hash> the
// sibling folder is twitter-2026-08-17-hydration, holding:
//
//     retweets.json — keyed by the archive's own retweet ID: the retweeted
//                     tweet as it really was, before the 140-char cut
//     quotes.json   — keyed by the quoted status ID: the quoted tweet
//     media/        — downloaded attachments, named "<tweet id>-<file>" like
//                     the archive's tweets_media folder
//
// The cache is permanent: re-opening the archive re-applies it offline (see
// HydrationOverlay), and a re-run of Retrieve only fetches what's new.
// Unavailable tweets are cached too — with the reason — so tombstones aren't
// re-fetched on every run.

import Foundation

/// One cached fetch: the tweet when it resolved, or why it didn't.
public struct HydrationRecord: Codable {
    public static let statusOK = "ok"
    public static let statusUnavailable = "unavailable"

    public var status: String
    /// The tombstone text ("This Post is from a suspended account…") when
    /// unavailable.
    public var reason: String?
    public var fetchedAt: Date
    public var tweet: HydratedTweetData?

    public var isOK: Bool { status == Self.statusOK }

    /// True when this record needs nothing more: the tweet came through AND
    /// every attachment it references actually landed on disk. A fetch that
    /// succeeded but whose downloads didn't is NOT done — it's retryable, or
    /// the attachment would be lost for good.
    public var isComplete: Bool {
        guard isOK, let tweet else { return false }
        return tweet.media.allSatisfy { $0.fileName != nil }
    }

    /// Attachments this record still owes.
    public var missingMediaCount: Int {
        guard isOK, let tweet else { return 0 }
        return tweet.media.filter { $0.fileName == nil }.count
    }
}

/// The distilled syndication response — just what the overlay needs.
public struct HydratedTweetData: Codable {
    public var idStr: String
    public var screenName: String
    public var name: String?
    /// ISO 8601, as the endpoint sends it ("2025-03-12T17:57:55.000Z").
    public var createdAt: String?
    public var text: String
    public var urls: [HydratedURL]
    public var media: [HydratedMediaFile]

    /// The display name, falling back to the @handle like the categorizer does.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return "@\(screenName)"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public var createdAtDate: Date? {
        guard let createdAt else { return nil }
        return Self.isoFormatter.date(from: createdAt)
            ?? ISO8601DateFormatter().date(from: createdAt)
    }
}

/// One entities.urls item of a fetched tweet.
public struct HydratedURL: Codable {
    public var tco: String
    public var expanded: String
    public var display: String?
}

/// One attachment of a fetched tweet. fileName is set once the download into
/// the store's media folder succeeded.
public struct HydratedMediaFile: Codable {
    /// The t.co link that stands in for the attachment in the text.
    public var tco: String?
    public var type: String  // "photo", "video", "animated_gif"
    public var sourceURL: String
    public var fileName: String?
}

public final class HydrationStore {

    public let folder: URL
    public var retweets: [String: HydrationRecord] = [:]
    public var quotes: [String: HydrationRecord] = [:]

    public var mediaFolder: URL { folder.appendingPathComponent("media") }
    private var retweetsFile: URL { folder.appendingPathComponent("retweets.json") }
    private var quotesFile: URL { folder.appendingPathComponent("quotes.json") }

    public init(archiveRoot: URL) {
        self.folder = Self.folderURL(for: archiveRoot)
    }

    public convenience init(for ref: TwitterArchiveRef) {
        self.init(archiveRoot: ref.archiveRoot)
    }

    /// twitter-2026-08-17-<hash> → twitter-2026-08-17-hydration, next to the
    /// archive; any other folder name just gets "-hydration" appended.
    static func folderURL(for archiveRoot: URL) -> URL {
        let name = archiveRoot.lastPathComponent
        let dated = PyRegex(#"^(twitter-\d{4}-\d{2}-\d{2})-.+$"#)
        let hydrationName: String
        if let m = dated.match(name), let prefix = m.group(1) {
            hydrationName = "\(prefix)-hydration"
        } else {
            hydrationName = "\(name)-hydration"
        }
        return archiveRoot.deletingLastPathComponent()
            .appendingPathComponent(hydrationName)
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: retweetsFile.path)
            || FileManager.default.fileExists(atPath: quotesFile.path)
    }

    public func mediaPath(_ fileName: String) -> URL {
        mediaFolder.appendingPathComponent(fileName)
    }

    // MARK: - Persistence

    public func load() {
        retweets = Self.read(retweetsFile) ?? [:]
        quotes = Self.read(quotesFile) ?? [:]
    }

    public func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        try Self.write(retweets, to: retweetsFile)
        try Self.write(quotes, to: quotesFile)
    }

    private static func read(_ url: URL) -> [String: HydrationRecord]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([String: HydrationRecord].self, from: data)
    }

    private static func write(_ records: [String: HydrationRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
    }
}
