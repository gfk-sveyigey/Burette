import SwiftUI
import UIKit

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

    private var entriesBinding: Binding<Int> {
        Binding(
            get: { center.maxEntries },
            set: { center.updateCleanup(maxEntries: $0, retentionDays: center.retentionDays) }
        )
    }

    private var daysBinding: Binding<Int> {
        Binding(
            get: { center.retentionDays },
            set: { center.updateCleanup(maxEntries: center.maxEntries, retentionDays: $0) }
        )
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
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Section("清理设置") {
                        Picker("保留条数", selection: entriesBinding) {
                            ForEach(LogCenter.Cleanup.entriesOptions, id: \.self) { value in
                                Text(LogCenter.Cleanup.entriesLabel(value)).tag(value)
                            }
                        }
                        Picker("保留天数", selection: daysBinding) {
                            ForEach(LogCenter.Cleanup.daysOptions, id: \.self) { value in
                                Text(LogCenter.Cleanup.daysLabel(value)).tag(value)
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        center.clear()
                    } label: {
                        Label("立即清空", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("日志清理设置")

                ShareLink(item: center.fileURL) {
                    Image(systemName: "square.and.arrow.up")
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
            .padding(.vertical, 4)
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
                Text(entry.category.label)
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
        .contextMenu {
            Button {
                UIPasteboard.general.string = text(entry)
            } label: {
                Label("复制这条日志", systemImage: "doc.on.doc")
            }
        }
    }

    private func text(_ entry: LogEntry) -> String {
        "\(time(entry.date)) [\(entry.level.rawValue)] [\(entry.category.label)] \(entry.message)"
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
