import SwiftUI

/// GitHub 风格的 unified diff 查看器：左侧旧/新行号栏，增删行用颜色区分。
struct DiffView: View {
    let original: String?
    let current: String

    private var lines: [LineDiff.Line] {
        LineDiff.compute(from: original, to: current)
    }

    private var stats: (added: Int, removed: Int) {
        LineDiff.stats(from: original, to: current)
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryBar

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        row(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(.systemBackground))
    }

    private var summaryBar: some View {
        HStack(spacing: 12) {
            Label("\(stats.added)", systemImage: "plus")
                .foregroundStyle(.green)
            Label("\(stats.removed)", systemImage: "minus")
                .foregroundStyle(.red)
            Spacer()
            Text("\(lines.count) 行")
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }

    private func row(_ line: LineDiff.Line) -> some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                numberText(line.oldNumber)
                numberText(line.newNumber)
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 0.5)
            }

            Text(sign(line.kind))
                .foregroundStyle(signColor(line.kind))
                .frame(width: 20, alignment: .center)

            Text(line.text.isEmpty ? " " : line.text)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 16)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .padding(.vertical, 1)
        .background(rowBackground(line.kind))
    }

    private func numberText(_ number: Int?) -> some View {
        Text(number.map { String($0) } ?? "")
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
            .padding(.horizontal, 6)
    }

    private func sign(_ kind: LineDiff.Kind) -> String {
        switch kind {
        case .context: return " "
        case .added: return "+"
        case .removed: return "-"
        }
    }

    private func signColor(_ kind: LineDiff.Kind) -> Color {
        switch kind {
        case .context: return .secondary
        case .added: return .green
        case .removed: return .red
        }
    }

    private func rowBackground(_ kind: LineDiff.Kind) -> Color {
        switch kind {
        case .context: return .clear
        case .added: return Color.green.opacity(0.14)
        case .removed: return Color.red.opacity(0.14)
        }
    }
}
