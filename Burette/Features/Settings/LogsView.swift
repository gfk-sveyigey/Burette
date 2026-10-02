import SwiftUI

struct LogsView: View {
    @ObservedObject private var center = LogCenter.shared
    @State private var levelFilter: LogLevel?

    private var filtered: [LogEntry] {
        let list: [LogEntry]
        if let levelFilter {
            list = center.entries.filter { $0.level == levelFilter }
        } else {
            list = center.entries
        }
        return list.reversed()
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "还没有日志",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("应用的操作记录会显示在这里。")
                )
            }

            ForEach(filtered) { entry in
                row(entry)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: center.logFileURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(center.entries.isEmpty)

                Button(role: .destructive) {
                    center.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(center.entries.isEmpty)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("级别", selection: $levelFilter) {
                Text("全部").tag(LogLevel?.none)
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(LogLevel?.some(level))
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: entry.level.symbol)
                    .font(.caption2)
                    .foregroundStyle(color(entry.level))
                Text(entry.level.rawValue)
                    .font(.caption2.bold())
                    .foregroundStyle(color(entry.level))
                Text(entry.category.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(time(entry.date))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func time(_ date: Date) -> String {
        Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
