import SwiftUI

/// 查看仓库的 GitHub Actions 运行记录（只读列表 + 详情 + 重新运行 / 取消）。
struct ActionsView: View {
    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository

    @State private var currentBranchOnly = true
    @State private var runs: [GitHubWorkflowRun] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var selectedRun: GitHubWorkflowRun?

    var body: some View {
        Group {
            if isLoading && runs.isEmpty {
                ProgressView("正在加载 Actions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText, runs.isEmpty {
                ContentUnavailableView(
                    "加载失败",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(errorText)
                )
            } else if runs.isEmpty {
                ContentUnavailableView(
                    "没有工作流运行",
                    systemImage: "bolt.horizontal.circle",
                    description: Text("这个仓库在所选分支上还没有 Actions 运行记录。")
                )
            } else {
                List {
                    ForEach(runs) { run in
                        Button {
                            selectedRun = run
                        } label: {
                            ActionRunRow(run: run)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Actions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("只看当前分支", isOn: $currentBranchOnly)
                    Button {
                        Task { await load() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $selectedRun) { run in
            NavigationStack {
                ActionRunDetailView(repository: repository, run: run) {
                    Task { await load() }
                }
            }
        }
        .task(id: currentBranchOnly) { await load() }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            let response = try await env.github.workflowRuns(
                owner: repository.owner,
                repo: repository.name,
                branch: currentBranchOnly ? repository.currentBranch : nil
            )
            runs = response.workflowRuns
            Log.info("加载 Actions：\(repository.fullName)，\(runs.count) 条记录", .github)
        } catch {
            if !Cancellation.isCancellation(error) {
                errorText = error.localizedDescription
                Log.error(error, .github)
            }
        }
        isLoading = false
    }
}

/// 列表里的一行运行记录。
struct ActionRunRow: View {
    let run: GitHubWorkflowRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: ActionFormat.symbol(for: run))
                    .foregroundStyle(ActionFormat.color(for: run))
                Text(run.displayTitle ?? run.name ?? "工作流运行")
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
                Text("#\(run.runNumber ?? run.id)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(ActionFormat.statusText(for: run))
                    .font(.caption.bold())
                    .foregroundStyle(ActionFormat.color(for: run))
                if let branch = run.headBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(ActionFormat.relative(run.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// 详情页：job / step 列表，以及重新运行与取消。
struct ActionRunDetailView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let repository: Repository
    let run: GitHubWorkflowRun
    var onChanged: () -> Void = {}

    @State private var jobs: [GitHubWorkflowJob] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var working = false

    var body: some View {
        List {
            Section("运行信息") {
                LabeledContent("状态", value: ActionFormat.statusText(for: run))
                LabeledContent("事件", value: run.event ?? "未知")
                if let branch = run.headBranch {
                    LabeledContent("分支", value: branch)
                }
                if let sha = run.headSha {
                    LabeledContent("提交", value: String(sha.prefix(7)))
                }
                LabeledContent("开始", value: ActionFormat.absolute(run.createdAt))
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
            }

            if isLoading {
                Section { HStack { ProgressView(); Text("正在加载任务…") } }
            } else if jobs.isEmpty {
                Section { Text("没有任务信息。").foregroundStyle(.secondary) }
            } else {
                ForEach(jobs) { job in
                    Section {
                        ForEach(job.steps ?? []) { step in
                            HStack(spacing: 8) {
                                Image(systemName: ActionFormat.stepSymbol(step.conclusion, status: step.status))
                                    .foregroundStyle(ActionFormat.stepColor(step.conclusion, status: step.status))
                                Text(step.name)
                                    .font(.footnote)
                                Spacer()
                                Text(ActionFormat.stepText(step.conclusion, status: step.status))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: ActionFormat.jobSymbol(job))
                                .foregroundStyle(ActionFormat.jobColor(job))
                            Text(job.name)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("运行 #\(run.runNumber ?? run.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await rerun() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(working)

                Button(role: .destructive) {
                    Task { await cancel() }
                } label: {
                    Image(systemName: "stop.circle")
                }
                .disabled(working || run.status != "in_progress" && run.status != "queued")
            }
        }
        .task { await loadJobs() }
        .refreshable { await loadJobs() }
    }

    private func loadJobs() async {
        isLoading = true
        errorText = nil
        do {
            let response = try await env.github.workflowJobs(
                owner: repository.owner,
                repo: repository.name,
                runID: run.id
            )
            jobs = response.jobs
        } catch {
            if !Cancellation.isCancellation(error) {
                errorText = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func rerun() async {
        working = true
        defer { working = false }
        do {
            try await env.github.rerunWorkflow(owner: repository.owner, repo: repository.name, runID: run.id)
            Log.info("已重新运行 workflow：\(repository.fullName) #\(run.id)", .github)
            onChanged()
            dismiss()
        } catch {
            errorText = error.localizedDescription
            Log.error(error, .github)
        }
    }

    private func cancel() async {
        working = true
        defer { working = false }
        do {
            try await env.github.cancelWorkflow(owner: repository.owner, repo: repository.name, runID: run.id)
            Log.info("已取消 workflow：\(repository.fullName) #\(run.id)", .github)
            onChanged()
            await loadJobs()
        } catch {
            errorText = error.localizedDescription
            Log.error(error, .github)
        }
    }
}

/// Actions 状态文案与配色。
enum ActionFormat {

    static func statusText(for run: GitHubWorkflowRun) -> String {
        text(conclusion: run.conclusion, status: run.status)
    }

    static func color(for run: GitHubWorkflowRun) -> Color {
        color(conclusion: run.conclusion, status: run.status)
    }

    static func symbol(for run: GitHubWorkflowRun) -> String {
        symbol(conclusion: run.conclusion, status: run.status)
    }

    static func text(conclusion: String?, status: String?) -> String {
        switch conclusion {
        case "success": return "成功"
        case "failure": return "失败"
        case "cancelled": return "已取消"
        case "skipped": return "已跳过"
        case "timed_out": return "超时"
        case "action_required": return "需要操作"
        case "neutral": return "中性"
        case "stale": return "已过期"
        case "startup_failure": return "启动失败"
        case let value?: return value
        case nil: break
        }
        switch status {
        case "in_progress": return "进行中"
        case "queued": return "排队中"
        case "waiting": return "等待中"
        case "requested": return "已请求"
        case "pending": return "等待中"
        case "completed": return "已完成"
        case let value?: return value
        default: return "未知"
        }
    }

    static func color(conclusion: String?, status: String?) -> Color {
        switch conclusion {
        case "success": return .green
        case "failure", "startup_failure": return .red
        case "timed_out", "action_required": return .orange
        case "cancelled", "skipped", "neutral", "stale": return .secondary
        default: break
        }
        switch status {
        case "in_progress": return .blue
        case "queued", "waiting", "requested", "pending": return .orange
        default: return .secondary
        }
    }

    static func symbol(conclusion: String?, status: String?) -> String {
        switch conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure", "startup_failure": return "xmark.circle.fill"
        case "cancelled": return "slash.circle.fill"
        case "skipped", "neutral": return "minus.circle.fill"
        case "timed_out", "action_required": return "exclamationmark.triangle.fill"
        default: break
        }
        switch status {
        case "in_progress": return "arrow.triangle.2.circlepath"
        case "queued", "waiting", "requested", "pending": return "clock"
        default: return "circle"
        }
    }

    static func jobColor(_ job: GitHubWorkflowJob) -> Color {
        color(conclusion: job.conclusion, status: job.status)
    }

    static func jobSymbol(_ job: GitHubWorkflowJob) -> String {
        symbol(conclusion: job.conclusion, status: job.status)
    }

    static func stepColor(_ conclusion: String?, status: String?) -> Color {
        color(conclusion: conclusion, status: status)
    }

    static func stepSymbol(_ conclusion: String?, status: String?) -> String {
        symbol(conclusion: conclusion, status: status)
    }

    static func stepText(_ conclusion: String?, status: String?) -> String {
        text(conclusion: conclusion, status: status)
    }

    /// "3 分钟前" 之类的相对时间。
    static func relative(_ iso: String?) -> String {
        guard let date = parse(iso) else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 本地时间 "MM-dd HH:mm"。
    static func absolute(_ iso: String?) -> String {
        guard let date = parse(iso) else { return "未知" }
        return absoluteFormatter.string(from: date)
    }

    private static func parse(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return isoFormatter.date(from: iso) ?? fallbackFormatter.date(from: iso)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
