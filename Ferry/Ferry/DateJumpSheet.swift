import SwiftUI

/// Month calendar for the date-jump feature. Days with messages show a small
/// dot. Since the server has no by-date endpoint, dots come from the model's
/// in-memory per-day counts (built from loaded messages plus a background
/// history scan); picking a day pages older until that day is reached.
struct DateJumpSheet: View {
    @Bindable var model: AppModel
    let onJump: (String) -> Void
    let onEmpty: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayedMonth = Calendar.current.startOfDay(for: Date())
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                monthHeader
                weekdayHeader
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                        if let date {
                            dayCell(date)
                        } else {
                            Color.clear.frame(height: 44)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 8)
            .navigationTitle("跳转到日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .overlay {
                if isSearching {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在查找…").font(.footnote).foregroundStyle(.secondary)
                        Button("取消") { cancelSearch() }
                            .buttonStyle(.bordered)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var monthHeader: some View {
        HStack {
            Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .accessibilityLabel("上个月")
            Spacer()
            Text(monthTitle).font(.headline)
            Spacer()
            Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .accessibilityLabel("下个月")
        }
        .padding(.horizontal, 8)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                Text(day).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: displayedMonth)
    }

    /// Leading nil placeholders for the first weekday, then one Date per day.
    private var days: [Date?] {
        let calendar = Calendar.current
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)),
              let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        var result: [Date?] = []
        let firstWeekday = calendar.component(.weekday, from: start)
        for _ in 1..<firstWeekday { result.append(nil) }
        for day in range {
            result.append(calendar.date(byAdding: .day, value: day - 1, to: start))
        }
        return result
    }

    private func dayCell(_ date: Date) -> some View {
        Button { pick(date) } label: {
            VStack(spacing: 3) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.body)
                    .foregroundStyle(Calendar.current.isDateInToday(date) ? Color.accentColor : .primary)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 4)
                    .opacity(hasMessages(date) ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hasMessages(_ date: Date) -> Bool {
        let key = DayKey.string(from: Calendar.current.startOfDay(for: date))
        return (model.dayCounts[key] ?? 0) > 0
    }

    private func changeMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        displayedMonth = Calendar.current.startOfDay(for: next)
    }

    private func pick(_ date: Date) {
        guard !isSearching else { return }
        isSearching = true
        searchTask = Task { @MainActor in
            let result = await model.locateDay(date)
            guard !Task.isCancelled else { isSearching = false; return }
            isSearching = false
            switch result {
            case .found(let id):
                dismiss()
                onJump(id)
            case .empty:
                dismiss()
                onEmpty()
            case .cancelled:
                break
            }
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}
