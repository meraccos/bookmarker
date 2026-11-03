import Foundation

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: UUID
    public var url: String
    public var title: String
    public var preview: String
    public var topics: [String]
    public var isFavorite: Bool = false
    public var isRead: Bool = false
    public var imageURL: String?
    public var iconURL: String?
    public var artworkChecked = false
    public var pageDescription: String?
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date
    public init(url: String, title: String = "", preview: String = "", topics: [String] = [], notes: String = "") {
        self.id = UUID(); self.url = url; self.title = title; self.preview = preview
        self.topics = Array(topics.prefix(1)); self.notes = notes; self.createdAt = Date(); self.updatedAt = Date()
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, url, title, preview, topics, notes, createdAt, updatedAt, isFavorite, isRead, imageURL, iconURL, artworkChecked, pageDescription }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        preview = try c.decode(String.self, forKey: .preview)
        topics = Array(try c.decode([String].self, forKey: .topics).prefix(1))
        notes = try c.decode(String.self, forKey: .notes)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        pageDescription = try c.decodeIfPresent(String.self, forKey: .pageDescription)
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        iconURL = try c.decodeIfPresent(String.self, forKey: .iconURL)
        artworkChecked = try c.decodeIfPresent(Bool.self, forKey: .artworkChecked) ?? false
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isRead = try c.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
    }
    public mutating func move(to topic: String?) {
        let value = topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        topics = value.isEmpty ? [] : [value]
    }
    public var host: String { URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url }
    public static func normalizedURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host(), host.contains("."), url.user == nil, url.password == nil else { return nil }
        return url
    }
}

public enum ArticleParser {
    public static func description(in html: String) -> String {
        let head = capture("<head[^>]*>([\\s\\S]*?)</head>", html) ?? html
        let tags = try! NSRegularExpression(pattern: "<meta\\b[^>]*>", options: .caseInsensitive)
        var descriptions: [String: String] = [:]
        for match in tags.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
            let values = attributes(in: (head as NSString).substring(with: match.range))
            let key = (values["name"] ?? values["property"] ?? "").lowercased()
            if let content = values["content"], !content.isEmpty, descriptions[key] == nil { descriptions[key] = content }
        }
        return descriptions["description"] ?? descriptions["og:description"] ?? descriptions["twitter:description"] ?? ""
    }
    private static func attributes(in tag: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
        var values: [String: String] = [:]
        let ns = tag as NSString
        for attr in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            let key = ns.substring(with: attr.range(at: 1)).lowercased()
            for index in 2...4 where attr.range(at: index).location != NSNotFound {
                values[key] = clean(ns.substring(with: attr.range(at: index))); break
            }
        }
        return values
    }
    public static func artwork(in html: String, pageURL: URL) -> (image: URL?, icon: URL?) {
        let tags = try! NSRegularExpression(pattern: "<(?:meta|link|base)\\b[^>]*>", options: .caseInsensitive)

        var image: String?; var twitter: String?; var icon: String?; var touch: String?
        var base = pageURL
        let head = capture("<head[^>]*>([\\s\\S]*?)</head>", html) ?? html
        for match in tags.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
            let tag = (head as NSString).substring(with: match.range)
            let values = attributes(in: tag)
            if tag.lowercased().hasPrefix("<base"), let href = values["href"], let url = URL(string: href, relativeTo: pageURL)?.absoluteURL, ["http", "https"].contains(url.scheme ?? "") { base = url }
            let property = (values["property"] ?? values["name"] ?? "").lowercased()
            if property == "og:image" || property == "og:image:url" { if image == nil { image = values["content"] } }
            if property == "twitter:image" || property == "twitter:image:src" { if twitter == nil { twitter = values["content"] } }
            let rel = (values["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            if rel.contains("icon"), icon == nil { icon = values["href"] }
            if rel.contains("apple-touch-icon"), touch == nil { touch = values["href"] }
        }
        func resolve(_ value: String?) -> URL? {
            guard let value, !value.isEmpty, let url = URL(string: value, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
        return (resolve(image) ?? resolve(twitter), resolve(icon) ?? resolve(touch))
    }
    public static func title(in html: String) -> String {
        capture("<title[^>]*>([\\s\\S]*?)</title>", html).map(clean) ?? ""
    }
    public static func fullText(in html: String) -> String {
        var body = html
        for tag in ["head", "script", "style", "nav", "header", "footer", "aside", "noscript", "form"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        body = capture("<main\\b[^>]*>([\\s\\S]*?)</main>", body)
            ?? capture("<article\\b[^>]*>([\\s\\S]*?)</article>", body)
            ?? body
        return clean(body)
    }
    public static func parse(_ html: String) -> (title: String, preview: String) {
        let title = Self.title(in: html)
        var body = html
        for tag in ["head", "script", "style", "nav", "header", "footer", "aside", "noscript", "form"] {
            body = body.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        body = capture("<article\\b[^>]*>([\\s\\S]*?)</article>", body) ?? capture("<main\\b[^>]*>([\\s\\S]*?)</main>", body) ?? body
        let regex = try! NSRegularExpression(pattern: "<p\\b[^>]*>([\\s\\S]*?)</p>", options: .caseInsensitive)
        let ns = body as NSString
        let paragraphs = regex.matches(in: body, range: NSRange(location: 0, length: ns.length)).map { clean(ns.substring(with: $0.range(at: 1))) }.filter { !$0.isEmpty }
        // Older essays often use <font> and line breaks instead of <p>.
        // Preserve block boundaries so dates and headings can be excluded.
        let text: String
        if !paragraphs.isEmpty {
            text = paragraphs.prefix(8).joined(separator: " ")
        } else {
            let blocks = body.replacingOccurrences(of: "<(?:br\\b[^>]*|/?(?:p|div|td|tr|h[1-6])\\b[^>]*)>", with: "\u{2029}", options: [.regularExpression, .caseInsensitive])
            let prose = blocks.components(separatedBy: "\u{2029}").map(clean).filter {
                !$0.isEmpty && $0.range(of: "[.!?](?:[\\s\"”’']|$)", options: .regularExpression) != nil
            }
            text = prose.prefix(8).joined(separator: " ")
        }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, stop in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if sentences.count == 2 { stop = true }
        }
        return (title, String(sentences.joined(separator: " ").prefix(1600)))
    }
    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private static func clean(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        let regex = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: text), let full = Range(match.range, in: text) else { continue }
            let code = String(text[range]); let number = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let number, let scalar = UnicodeScalar(number) { text.replaceSubrange(full, with: String(scalar)) }
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
