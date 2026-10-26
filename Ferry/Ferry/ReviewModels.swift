import Foundation
import SwiftUI

// MARK: - Kind

/// The four kinds of things 总管 puts in front of the 局长.
///
/// The raw value is what travels on the wire (`kind` in the `review` JSON
/// field, or `[待查看:kind]` in the plain-text form), so it is fixed English
/// regardless of what the UI shows.
enum ReviewKind: String, Codable, Sendable {
    /// 待测新包
    case package
    /// 等他拍板的事
    case decision
    /// 日报摘要
    case daily
    /// 完成汇报
    case report

    var title: String {
        switch self {
        case .package: "待测新包"
        case .decision: "待拍板"
        case .daily: "日报摘要"
        case .report: "完成汇报"
        }
    }

    var symbol: String {
        switch self {
        case .package: "shippingbox.fill"
        case .decision: "questionmark.circle.fill"
        case .daily: "doc.text.fill"
        case .report: "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .package: Color.orange
        case .decision: Color.purple
        case .daily: Color.blue
        case .report: Color.green
        }
    }
}

// MARK: - Item

/// One entry in the 待查看 list, derived from a message that carries the
/// review marker (see `ReviewItemParser`).
struct ReviewItem: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ReviewKind
    let title: String
    let summary: String
    let detail: String?
    /// Sequence of the source message, so the list mirrors timeline order.
    let sequence: Int64
    /// `created_at` of the source message, kept verbatim (UTC RFC 3339).
    let createdAt: String

    var timeText: String {
        guard let date = TimestampFormat.date(from: createdAt) else { return "" }
        return TimestampFormat.time.string(from: date)
    }

    var dayText: String { TimestampFormat.dayLabel(from: createdAt) }

    /// "今天 14:32" (or "2026年10月26日 09:05" for older days).
    var listTimeText: String {
        let time = timeText
        if time.isEmpty { return dayText }
        if dayText.isEmpty { return time }
        return "\(dayText) \(time)"
    }

    /// Placeholder for an item whose 说明 line was empty.
    var displaySummary: String {
        summary.isEmpty ? "（无说明）" : summary
    }
}

// MARK: - Placement

enum ReviewPlacement {
    /// The pinned 待查看 entry belongs to the 总管 page. `chief` is the fixed
    /// id of that assistant in `AssistantStore.builtIn`.
    static let chiefAssistantID = "chief"
}

// MARK: - Reply formatting

enum ReviewReplyFormatter {
    /// A reply to a 待查看 item is an ordinary outgoing text message that
    /// quotes the item: a machine-readable first line carrying the item id
    /// (so the other side can correlate it), then the typed body.
    ///
    /// ```
    /// [回复待查看:r-42] Ferry iOS build 13 待测
    /// 我看过了，可以发。
    /// ```
    static func body(for item: ReviewItem, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "[回复待查看:\(item.id)] \(item.title)\n\(trimmed)"
    }
}
