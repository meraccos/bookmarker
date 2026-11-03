import Foundation
import BookmarkCore

@main struct BookmarkChecks {
    static func main() throws {
        testExtractsFirstTwoArticleSentencesAndIgnoresNavigation()
        testCombinesParagraphsAndRemovesScript()
        testNoReadableTextHasEmptyPreview()
        testURLValidation()
        try testPortableJSONRoundTrip()
        testLegacyHTMLPreview()
        try testLegacyBookmarkDefaultsAndMoves()
        testArtworkMetadata()
        testArtworkFallbackAndUnsafeURLs()
        testHTMLDescriptions()
        testFullTextExtraction()
        testSidebarTotals()
        testSafariSaveRequests()
        testSorting()
        print("Passed all 14 bookmark core checks.")
    }
    static func testExtractsFirstTwoArticleSentencesAndIgnoresNavigation() {
        let html = """
        <title>A &amp; B &#8212; Reading</title><nav><p>This navigation paragraph should never appear in the resulting article preview.</p></nav>
        <article><p>The first sentence contains enough words to be a useful article paragraph. Here is the second sentence! This is the third sentence.</p></article>
        """
        let result = ArticleParser.parse(html)
        precondition(result.title == "A & B — Reading")
        precondition(result.preview == "The first sentence contains enough words to be a useful article paragraph. Here is the second sentence!")
    }
    static func testCombinesParagraphsAndRemovesScript() {
        let result = ArticleParser.parse("<main><script><p>This is a fake paragraph that should never be included in the preview.</p></script><p>This first paragraph has enough words for extraction.</p><p>This second paragraph also has enough words for extraction.</p></main>")
        precondition(result.preview == "This first paragraph has enough words for extraction. This second paragraph also has enough words for extraction.")
    }
    static func testNoReadableTextHasEmptyPreview() { precondition(ArticleParser.parse("<title>App</title><script>render()</script>").preview == "") }
    static func testURLValidation() {
        precondition(Bookmark.normalizedURL("example.com/read")?.absoluteString == "https://example.com/read")
        precondition(Bookmark.normalizedURL("javascript://example.com") == nil)
        precondition(Bookmark.normalizedURL("https://user:password@example.com") == nil)
        precondition(Bookmark.normalizedURL("not a web address") == nil)
    }
    static func testPortableJSONRoundTrip() throws {
        let bookmark = Bookmark(url: "https://example.com", title: "Reading", topics: ["Design"], notes: "A thought")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(Bookmark.self, from: encoder.encode(bookmark))
        precondition(result.id == bookmark.id); precondition(result.topics == ["Design"]); precondition(result.notes == "A thought")
    }
    static func testLegacyHTMLPreview() {
        let html = """
        <html><head><title>Life is Short</title></head><body><table><tr><td><img alt="Logo"></td><td>
        <font size="2">January 2016<br /><br />Life is short, as everyone knows. When I was a kid I used to wonder
        about this. A third sentence should be excluded.<br><br>More article text follows.</font></td></tr></table></body></html>
        """
        let result = ArticleParser.parse(html)
        precondition(result.title == "Life is Short")
        precondition(result.preview == "Life is short, as everyone knows. When I was a kid I used to wonder about this.")
        let unclosed = ArticleParser.parse("<body><p>A short first sentence.<p>A second sentence.<p>A third sentence.</body>")
        precondition(unclosed.preview == "A short first sentence. A second sentence.")
    }
    static func testLegacyBookmarkDefaultsAndMoves() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let original = Bookmark(url: "https://example.com")
        var json = try JSONSerialization.jsonObject(with: encoder.encode(original)) as! [String: Any]
        json.removeValue(forKey: "isFavorite"); json.removeValue(forKey: "isRead")
        json.removeValue(forKey: "pageDescription"); json.removeValue(forKey: "artworkChecked"); json.removeValue(forKey: "imageURL"); json.removeValue(forKey: "iconURL")
        json["topics"] = ["Design", "Reading"]
        var migrated = try decoder.decode(Bookmark.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(!migrated.isFavorite && !migrated.isRead)
        precondition(migrated.pageDescription == nil)
        precondition(!migrated.artworkChecked && migrated.imageURL == nil && migrated.iconURL == nil)
        precondition(migrated.topics == ["Design"])
        migrated.isFavorite = true; migrated.isRead = true
        migrated.move(to: "Writing")
        precondition(migrated.topics == ["Writing"])
        migrated.move(to: nil)
        precondition(migrated.topics.isEmpty)
        let saved = try decoder.decode(Bookmark.self, from: encoder.encode(migrated))
        precondition(saved.isFavorite && saved.isRead && saved.topics.isEmpty)
    }

    static func testArtworkMetadata() {
        let html = """
        <head><meta name='twitter:image' content='/twitter.jpg'>
        <meta content="../cover.jpg?a=1&amp;b=2" property="og:image">
        <link href='/icon.png' rel='shortcut icon'></head>
        <body><meta property='og:image' content='/wrong-body.jpg'></body>
        """
        let result = ArticleParser.artwork(in: html, pageURL: URL(string: "https://example.com/blog/post")!)
        precondition(result.image?.absoluteString == "https://example.com/cover.jpg?a=1&b=2")
        precondition(result.icon?.absoluteString == "https://example.com/icon.png")
    }
    static func testArtworkFallbackAndUnsafeURLs() {
        let html = """
        <meta property='og:image' content='file:///private/image.jpg'>
        <meta name=twitter:image content='//cdn.example.com/photo.png'>
        <link rel=apple-touch-icon href='/touch.png'>
        """
        let result = ArticleParser.artwork(in: html, pageURL: URL(string: "https://example.com/blog")!)
        precondition(result.image?.absoluteString == "https://cdn.example.com/photo.png")
        precondition(result.icon?.absoluteString == "https://example.com/touch.png")
        let empty = ArticleParser.artwork(in: "<title>No images</title>", pageURL: URL(string: "https://example.com")!)
        precondition(empty.image == nil && empty.icon == nil)
    }

    static func testHTMLDescriptions() {
        let html = """
        <head><meta property='og:description' content='Social fallback'>
        <META CONTENT="A short &amp; useful description.&#10;More detail." NAME="description"></head>
        <body><meta name='description' content='Wrong body text'></body>
        """
        precondition(ArticleParser.description(in: html) == "A short & useful description. More detail.")
        precondition(ArticleParser.description(in: "<meta property='og:description' content='Open Graph text'>") == "Open Graph text")
        precondition(ArticleParser.description(in: "<meta name='description' content='  '><meta name='twitter:description' content='Twitter text'>") == "Twitter text")
        precondition(ArticleParser.description(in: "<title>No description</title><p>Article content.</p>") == "")
    }

    static func testFullTextExtraction() {
        let html = "<head><style>hidden</style></head><body><nav>menu</nav><main>Unique searchable phrase &amp; more text.</main></body>"
        precondition(ArticleParser.fullText(in: html) == "Unique searchable phrase & more text.")
    }

    static func testSidebarTotals() {
        var inbox = Bookmark(url: "https://example.com/inbox")
        inbox.isFavorite = true
        var read = Bookmark(url: "https://example.com/read", topics: ["Reading"])
        read.isRead = true
        var unread = Bookmark(url: "https://example.com/unread", topics: ["Reading"])
        unread.isFavorite = true
        let other = Bookmark(url: "https://example.com/other", topics: ["Design"])
        let summary = BookmarkSummary([inbox, read, unread, other])
        precondition(summary.inbox == 1 && summary.favorites == 2)
        precondition(summary.topicCounts == ["Reading": 2, "Design": 1])
        precondition(summary.topics == ["Design", "Reading"])
        precondition(BookmarkSummary([]).topics.isEmpty)
    }

    static func testSorting() {
        var older = Bookmark(url: "https://example.com/older", title: "Zulu")
        var newer = Bookmark(url: "https://example.com/newer", title: "Alpha")
        older.createdAt = Date(timeIntervalSince1970: 100)
        newer.createdAt = Date(timeIntervalSince1970: 200)
        older.updatedAt = Date(timeIntervalSince1970: 300)
        let records = [older, newer]
        precondition(records.sorted(by: BookmarkSortOrder.newestAdded.precedes).map(\.id) == [newer.id, older.id])
        precondition(records.sorted(by: BookmarkSortOrder.oldestAdded.precedes).map(\.id) == [older.id, newer.id])
        precondition(records.sorted(by: BookmarkSortOrder.titleAscending.precedes).first?.id == newer.id)
        precondition(records.sorted(by: BookmarkSortOrder.titleDescending.precedes).first?.id == older.id)
        newer.createdAt = older.createdAt
        let forward = [older, newer].sorted(by: BookmarkSortOrder.newestAdded.precedes)
        let reverse = [newer, older].sorted(by: BookmarkSortOrder.newestAdded.precedes)
        precondition(forward == reverse, "Equal dates must have stable ordering")
    }

    static func testSafariSaveRequests() {
        var url = URLComponents()
        url.scheme = "bookmarker"; url.host = "save"
        url.queryItems = [URLQueryItem(name: "url", value: "https://example.com/post?a=1&b=two#section"), URLQueryItem(name: "title", value: "A & B — 100%")]
        let request = BookmarkSaveRequest(url: url.url!)
        precondition(request?.pageURL.absoluteString == "https://example.com/post?a=1&b=two#section")
        precondition(request?.title == "A & B — 100%")
        precondition(BookmarkSaveRequest(url: URL(string: "bookmarker://save?url=file:///etc/passwd")!) == nil)
        precondition(BookmarkSaveRequest(url: URL(string: "https://save?url=https://example.com")!) == nil)
        precondition(BookmarkSaveRequest(url: URL(string: "bookmarker://delete?url=https://example.com")!) == nil)
    }

}
