import Foundation

/// Turns a Ferry message into a 待查看 item.
///
/// Two shapes are accepted — the server side may send either:
///
/// **1. JSON.** The message carries an object with a `review` field:
///
/// ```json
/// {"review":{"id":"r-42","kind":"package","title":"build 13 待测",
///            "summary":"装上去过一遍待查看区","detail":"1. …\n2. …"}}
/// ```
///
/// The object may sit anywhere in the text (a ``` fence is stripped first) and
/// may be nested inside another object; every balanced `{ … }` run is tried.
/// `detail` is optional; an unknown `kind` is ignored.
///
/// **2. Plain text.** The first line is the marker, the second line is the
/// 说明, and everything after it is the 详情:
///
/// ```
/// [待查看:daily] 10 月 26 日日报
/// 今日完成 3 项，待确认 1 项。
/// 明细……
/// ```
///
/// Full-width brackets/colon (`【待查看：daily】`) are tolerated.
///
/// An id that is missing (plain text has none) falls back to the message id,
/// which is what the local 已看 state keys on. A message without a marker is
/// simply not a 待查看 message — it keeps rendering in the timeline exactly
/// as it did before.
enum ReviewItemParser {

    /// Parse one incoming message. Own messages are never review items.
    static func parse(message: MessagePayload) -> ReviewItem? {
        guard !message.isCurrentDevice else { return nil }
        guard let text = message.text, !text.isEmpty else { return nil }
        return parseJSON(text, message: message) ?? parsePlainText(text, message: message)
    }

    // MARK: - Shared builder

    /// Validate the raw fields and build the item. Returns nil for a kind
    /// outside the four agreed values (that message stays a plain message).
    private static func makeItem(id: String?, rawKind: String, title: String, summary: String,
                                 detail: String?, message: MessagePayload) -> ReviewItem? {
        let trimmedKind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let kind = ReviewKind(rawValue: trimmedKind) else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReviewItem(
            id: trimmedID.isEmpty ? message.id : trimmedID,
            kind: kind,
            title: trimmedTitle.isEmpty ? kind.title : trimmedTitle,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            detail: (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil,
            sequence: message.sequence,
            createdAt: message.createdAt
        )
    }

    // MARK: - JSON form

    private struct Envelope: Decodable {
        let review: Payload
    }

    private struct Payload: Decodable {
        let id: String
        let kind: String
        let title: String
        let summary: String
        let detail: String?

        enum CodingKeys: String, CodingKey { case id, kind, title, summary, detail }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = Self.string(container, .id)
            kind = Self.string(container, .kind)
            title = Self.string(container, .title)
            summary = Self.string(container, .summary)
            detail = try? container.decode(String.self, forKey: .detail)
        }

        /// Tolerates an id sent as a number instead of a string.
        private static func string(_ container: KeyedDecodingContainer<CodingKeys>,
                                   _ key: CodingKeys) -> String {
            if let value = try? container.decode(String.self, forKey: key) { return value }
            if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
            return ""
        }
    }

    private static func parseJSON(_ text: String, message: MessagePayload) -> ReviewItem? {
        let source = strippingCodeFence(text)
        for candidate in balancedObjects(in: source) {
            guard let data = candidate.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { continue }
            let payload = envelope.review
            return makeItem(id: payload.id, rawKind: payload.kind, title: payload.title,
                            summary: payload.summary, detail: payload.detail, message: message)
        }
        return nil
    }

    /// Drop ```json … ``` fences so the object inside is still found.
    private static func strippingCodeFence(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var kept: [String] = []
        for line in lines where !line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Every balanced `{ … }` run, outermost first. String literals and escapes
    /// are respected, so a brace inside a title cannot confuse the scan.
    private static func balancedObjects(in text: String) -> [String] {
        let chars = Array(text)
        var results: [String] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "{" {
                if let end = closingBrace(in: chars, from: index) {
                    results.append(String(chars[index...end]))
                    index = end + 1
                    continue
                }
            }
            index += 1
        }
        return results
    }

    private static func closingBrace(in chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < chars.count {
            let char = chars[index]
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Plain-text form

    /// `[待查看:kind] 标题` (full-width brackets/colon tolerated). Built once;
    /// `!` is safe because the pattern is a literal.
    private static let headerRegex = try! NSRegularExpression(
        pattern: #"^\s*[\[【]\s*待查看\s*[:：]\s*([A-Za-z]+)\s*[\]】]\s*(.*)$"#,
        options: []
    )

    private static func parsePlainText(_ text: String, message: MessagePayload) -> ReviewItem? {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first else { return nil }
        guard let match = headerRegex.firstMatch(in: first, options: [],
                                                 range: NSRange(first.startIndex..., in: first)),
              let kindRange = Range(match.range(at: 1), in: first),
              let titleRange = Range(match.range(at: 2), in: first) else { return nil }

        // 下一行为说明，其余为详情. Blank lines between the title and the
        // summary are skipped rather than treated as an empty summary.
        var rest = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        var summary = ""
        while let line = rest.first {
            rest.removeFirst()
            if line.isEmpty { continue }
            summary = line
            break
        }
        let detail = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return makeItem(id: nil,
                        rawKind: String(first[kindRange]),
                        title: String(first[titleRange]),
                        summary: summary,
                        detail: detail.isEmpty ? nil : detail,
                        message: message)
    }
}
