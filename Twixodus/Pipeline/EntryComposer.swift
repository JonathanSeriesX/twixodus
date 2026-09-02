// Step 5b of the pipeline: compose the Day One entry for one thread.
//
// Takes a categorized thread and produces everything the entry needs: the
// Markdown body with per-tweet like/retweet counts, the tags, the media
// attachments, the entry date and location, plus a title (LLM-generated when
// enabled) and the journal it belongs in.

import Foundation

public enum EntryComposer {

    /// Escapes Markdown so tweet text can't accidentally format the entry.
    static func escapeMarkdown(_ text: String) -> String {
        // 1) Handle line-start markers
        var lines: [String] = []
        for (idx, var line) in text.pySplitlines().enumerated() {
            // only escape "# " headings if not the very first line
            if line.hasPrefix("# ") && idx != 0 {
                line = "\\" + line
            } else if let first = line.first, "-+>".contains(first) {
                // escape lists & blockquotes
                line = "\\" + line
            }
            lines.append(line)
        }
        var escaped = lines.joined(separator: "\n")

        // 2) Escape inline markdown chars. The .literal option matches raw
        // code units the way Python's str.replace does — without it, a '*'
        // that's part of a combining grapheme cluster would be skipped.
        for ch in ["*", "`", "|", "!"] {
            escaped = escaped.replacingOccurrences(of: ch, with: "\\" + ch, options: .literal)
        }

        return escaped
    }

    /// Walks the thread once and gathers everything the entry needs: the
    /// combined text (each tweet followed by its like/retweet counts), the
    /// hashtags as tags, the media attachments, the first tweet's date, and
    /// the first geotag found.
    public static func aggregateThreadData(_ thread: TweetThread, config: ImportConfig) -> EntryContent {
        var entryText = ""
        var entryTags: [String] = []
        var entryMediaFiles: [String] = []
        var entryDate: Date?
        var entryCoordinate: (latitude: Double, longitude: Double)?
        var firstTweetDate: Date?

        for (i, tweet) in thread.enumerated() {
            let currentTweetDate = tweet.createdAt

            if i == 0 {
                firstTweetDate = currentTweetDate
                entryDate = currentTweetDate
            }

            entryText += tweet.fullText + "\n\n"

            if let quote = tweet.hydratedQuote {
                entryText += quoteBlock(quote, quotingDate: currentTweetDate) + "\n\n"
            }

            var metrics: [String] = []
            let likes = tweet.favoriteCount
            let retweets = tweet.retweetCount

            if let username = config.currentUsername, !username.isEmpty {
                let tweetURL = "https://twitter.com/\(username)/status/\(tweet.idStr)"
                if likes > 0 {
                    metrics.append("[Likes: \(likes)](\(tweetURL)/likes) ⭐️")
                }
                if retweets > 0 {
                    metrics.append("[Retweets: \(retweets)](\(tweetURL)/retweets) 🔁")
                }
                metrics.append("[Open on twitter.com](\(tweetURL))")
            } else {
                if likes > 0 {
                    metrics.append("Likes: \(likes) ⭐️")
                }
                if retweets > 0 {
                    metrics.append("Retweets: \(retweets) 🔁")
                }
            }

            var timeDiffStr = ""
            if i > 0, let firstDate = firstTweetDate {
                // Note how much later than the thread's start this tweet was
                // sent, once the gap is big enough to be interesting.
                let timeDiff = currentTweetDate.timeIntervalSince(firstDate)
                if timeDiff > 10 * 60 {
                    timeDiffStr = " (sent \(Humanize.naturalDelta(timeDiff)) later)"
                }
            }

            entryText += metrics.joined(separator: "   ") + timeDiffStr + "\n"
            entryText += "___\n"

            entryTags.append(contentsOf: tweet.hashtags)
            entryMediaFiles.append(contentsOf: tweet.mediaFiles)

            if entryCoordinate == nil, let coordinate = tweet.coordinate {
                entryCoordinate = coordinate
            }
        }

        return EntryContent(
            text: entryText,
            tags: entryTags,
            mediaFiles: entryMediaFiles,
            date: entryDate,
            coordinate: entryCoordinate
        )
    }

    /// Marks a line as a real blockquote line. escapeMarkdown() escapes every
    /// ">" the TWEET text starts a line with (a tweet must never format the
    /// entry) — this private-use character smuggles our own, intentional
    /// blockquotes past it, and buildEntryContent turns it into "> " at the
    /// very end.
    static let blockquoteMarker = "\u{E000}"

    private static let quoteDateSameYear = PipelineDates.formatter("MMM d")
    private static let quoteDateOtherYear = PipelineDates.formatter("MMM d, yyyy")

    /// The retrieved quoted tweet as a blockquote:
    ///
    ///     > Quoting [unusual_whales from Jan 12](https://twitter.com/...):
    ///     > Gen Z has cut down on their effort at work…
    ///
    /// The year is added only when the quoted tweet is from a different year
    /// than the quoting one.
    static func quoteBlock(_ quote: HydratedQuote, quotingDate: Date) -> String {
        let url = "https://twitter.com/\(quote.screenName)/status/\(quote.statusId)"

        var label = quote.name
        if let date = quote.createdAt {
            let calendar = PipelineDates.utcCalendar
            let sameYear = calendar.component(.year, from: date)
                == calendar.component(.year, from: quotingDate)
            let formatter = sameYear ? quoteDateSameYear : quoteDateOtherYear
            label += " from \(formatter.string(from: date))"
        }

        var lines = ["Quoting [\(label)](\(url)):"]
        let text = quote.text.isEmpty ? "…" : quote.text
        lines.append(contentsOf: text.pySplitlines())
        return lines.map { blockquoteMarker + $0 }.joined(separator: "\n")
    }

    /// Generates the title for the Day One entry, optionally using an LLM.
    ///
    /// The LLM produces a full action phrase ("Expressed frustration at airport
    /// security", "Posted a meme about cats") from the entry text and, for vision
    /// models, its attached images. It only runs for the author's own content —
    /// threads and standalone tweets; replies, retweets, quotes, and callouts keep
    /// their descriptive category titles. When the LLM can't produce a confident
    /// title, the category ("Wrote a thread" / "Tweeted") is used as-is.
    ///
    /// The LLM call is injected so the pure pipeline stays network-free.
    public static func generateEntryTitle(
        entryText: String,
        category: String,
        threadLength: Int,
        mediaFiles: [String],
        config: ImportConfig,
        llmTitle: (String, [String]) async -> String?
    ) async -> String {
        // The blockquote marker is an internal encoding — the LLM gets
        // readable quotes.
        let entryText = entryText.replacingOccurrences(of: blockquoteMarker, with: "> ")
        if !config.processTitlesWithLLM { return category }
        if category.hasPrefix("Replied to") { return category }

        let isThread = threadLength > 1
        let isSingleTweet = category == "Tweeted" && config.llmTitlesForSingleTweets
        if !(isThread || isSingleTweet) { return category }

        if let title = await llmTitle(entryText, mediaFiles) {
            return title
        }
        return category
    }

    private static let sourceLinkRegex = PyRegex(#"<a href="([^"]*)"[^>]*>([^<]+)</a>"#)
    private static let htmlTagRegex = PyRegex(#"<[^>]+>"#)

    /// Converts a tweet's HTML "source" field — the client it was posted from,
    /// e.g. '<a href="http://twitter.com/download/android" rel="nofollow">Twitter
    /// for Android</a>' — into a Markdown link. Sources without a link (old tweets
    /// just say "web") are returned as plain text. Returns nil if there's nothing
    /// usable.
    static func formatSourceMarkdown(_ source: String?) -> String? {
        guard let source, !source.isEmpty else { return nil }
        if let m = sourceLinkRegex.search(source) {
            let url = m.group(1) ?? ""
            let name = (m.group(2) ?? "").pyStrip()
            if !name.isEmpty {
                return url.isEmpty ? name : "[\(name)](\(url))"
            }
        }
        let text = htmlTagRegex.sub("", source).pyStrip()
        return text.isEmpty ? nil : text
    }

    private static let mentionRegex = PyRegex(#"@\w+"#)
    private static let mentionRunRegex = PyRegex(#"(?:@\w+\s*)+"#)

    /// Constructs the final text content for the Day One entry: the title as a
    /// heading, then the body, then — for replies — the conversation context, or
    /// — for own tweets — the "Sent from <client>" footer.
    public static func buildEntryContent(
        entryText: String, firstTweet: Tweet, category: String, title: String,
        config: ImportConfig, isContinuation: Bool = false
    ) -> String {
        // A continuation part of a split thread carries just the tweets — the
        // reply context and the client footer live on the first part.
        if isContinuation {
            return escapeMarkdown("# \(title)\n\n\(entryText)\n\n")
        }

        var entryText = entryText

        if let replyToId = firstTweet.inReplyToStatusIdStr {
            // Extract mentions in the order they appear, removing duplicates
            // while preserving order.
            var seen = Set<String>()
            var mentions: [String] = []
            for m in mentionRegex.findAll(entryText) {
                guard let mention = m.group(0) else { continue }
                if !seen.contains(mention) {
                    mentions.append(mention)
                    seen.insert(mention)
                }
            }
            let rest = mentionRunRegex.sub("", entryText).pyStrip()
            let mentionsStr = mentions.joined(separator: " ")
            entryText = "\(rest)\n\n"
            let replyToURL = "https://twitter.com/i/web/status/\(replyToId)"
            entryText += "In response to [this tweet](\(replyToURL)), "
                + "which is part of the conversation with \(mentionsStr)\n"
        } else if config.showTweetSource {
            // A thread is stamped with its first tweet's client.
            if let sourceMd = formatSourceMarkdown(firstTweet.source) {
                entryText += "Sent from \(sourceMd)\n"
            }
        }

        return escapeMarkdown("# \(title)\n\n\(entryText)\n\n")
            .replacingOccurrences(of: blockquoteMarker, with: "> ")
    }

    /// Determines the target journal for the entry, or nil to skip it
    /// (replies with no reply journal configured, retweets when ignored).
    public static func targetJournal(
        category: String, tweetId: String, config: ImportConfig,
        log: (String) -> Void = { _ in }
    ) -> String? {
        var journal = config.journalName
        if category.hasPrefix("Replied to") {
            if let replyJournal = config.replyJournalName {
                journal = replyJournal
            } else {
                log("Skipping reply thread \(tweetId) as the reply journal is not set.")
                return nil
            }
        }
        if category.hasPrefix("Retweet"), config.ignoreRetweets {
            log("Skipping retweet \(tweetId) as retweets are ignored.")
            return nil
        }
        return journal
    }
}
