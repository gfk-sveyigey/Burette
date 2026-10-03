import SwiftUI

// MARK: - 列表

/// 查看仓库的 GitHub Actions 运行记录：列表 + 详情 + 重新运行 / 取消。
struct ActionsView: View {
    /// 列表展示范围。
    private enum BranchScope: Hashable, CaseIterable, Identifiable {
        case all
        case current

        var id: Self { self }

        func label(currentBranch: String) -> String {
            switch self {
            case .all: return "全部分支"
            case .current: return "只看当前分支（\(currentBranch)）"
            }
        }

        var shortLabel: String {
            switch self {
            case .all: return "全部分支"
            case .current: return "只看当前分支"
            }
        }
    }

    @EnvironmentObject private var env: AppEnvironment
    let repository: Repository

    /// 默认展示所有分支，否则进行中的运行不在当前分支就会「看不到」。
    @State private var scope: BranchScope = .all
    @State private var runs: [GitHubWorkflowRun] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var selectedRun: GitHubWorkflowRun?

    var body: some View {
        content
            .navigationTitle("Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarMenu }
            .sheet(item: $selectedRun) { run in
                NavigationStack {
                    ActionRunDetailView(repository: repository, run: run) {
                        Task { await load() }
                    }
                }
            }
            .task(id: scope) { await load() }
            // 有运行未结束时自动刷新，方便盯着正在进行的 Actions。
            .task(id: hasActiveRun) { await pollWhileActive() }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if isLoading && runs.isEmpty {
            ProgressView("正在加载 Actions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = errorText, runs.isEmpty {
            ContentUnavailableView(
                "加载失败",
                systemImage: "exclamationmark.triangle.fill",
                description: Text(message)
            )
        } else if runs.isEmpty {
            ContentUnavailableView(
                "没有工作流运行",
                systemImage: "bolt.horizontal.circle",
                description: Text("这个仓库还没有 Actions 运行记录，或当前令牌没有 Actions 读取权限。")
            )
        } else {
            List {
                Section { scopeRow }

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

    /// 顶部信息行：仓库 / 分支范围 + 进行中指示。
    private var scopeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(repository.fullName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(scope.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if hasActiveRun {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("进行中")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
            } else {
                Text("\(runs.count) 条")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("分支范围", selection: $scope) {
                    ForEach(BranchScope.allCases) { option in
                        Text(option.label(currentBranch: repository.currentBranch)).tag(option)
                    }
                }
                Button {
                    Task { await load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Actions 选项")
        }
    }

    // MARK: 数据

    /// 是否有排队 / 进行中的运行。
    private var hasActiveRun: Bool {
        runs.contains { ActionFormat.isActive(status: $0.status) }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            let response = try await env.github.workflowRuns(
                owner: repository.owner,
                repo: repository.name,
                branch: scope == .current ? repository.currentBranch : nil
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

    private func pollWhileActive() async {
        guard hasActiveRun else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if Task.isCancelled { break }
            await load()
        }
    }
}

// MARK: - 列表行

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

// MARK: - 详情

/// 详情页：运行信息 + job / step 状态，以及重新运行与取消。
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
            runSection
            errorSection

            if isLoading {
                Section { HStack(spacing: 8) { ProgressView(); Text("正在加载任务…") } }
            } else if jobs.isEmpty {
                Section { Text("没有任务信息。").foregroundStyle(.secondary) }
            } else {
                ForEach(jobs) { job in jobSection(job) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("运行 #\(run.runNumber ?? run.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .task { await loadJobs() }
        .refreshable { await loadJobs() }
        .task(id: hasActiveJob) { await pollWhileActive() }
    }

    // MARK: 内容

    private var runSection: some View {
        Section("运行信息") {
            LabeledContent("状态") {
                Image(systemName: ActionFormat.symbol(for: run))
                    .foregroundStyle(ActionFormat.color(for: run))
            }
            LabeledContent("事件", value: run.event ?? "未知")
            if let branch = run.headBranch {
                LabeledContent("分支", value: branch)
            }
            if let sha = run.headSha {
                LabeledContent("提交", value: String(sha.prefix(7)))
            }
            LabeledContent("开始", value: ActionFormat.absolute(run.createdAt))
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = errorText {
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func jobSection(_ job: GitHubWorkflowJob) -> some View {
        Section {
            if let steps = job.steps, !steps.isEmpty {
                ForEach(steps) { step in
                    stepRow(step)
                }
            } else {
                Text("没有步骤信息")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: ActionFormat.symbol(conclusion: job.conclusion, status: job.status))
                    .foregroundStyle(ActionFormat.color(conclusion: job.conclusion, status: job.status))
                Text(job.name)
            }
        }
    }

    private func stepRow(_ step: GitHubWorkflowStep) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ActionFormat.symbol(conclusion: step.conclusion, status: step.status))
                .foregroundStyle(ActionFormat.color(conclusion: step.conclusion, status: step.status))
            Text(step.name)
                .font(.footnote)
            Spacer()
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
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
            .accessibilityLabel("重新运行")

            Button(role: .destructive) {
                Task { await cancel() }
            } label: {
                Image(systemName: "stop.circle")
            }
            .disabled(working || !canCancel)
            .accessibilityLabel("取消运行")
        }
    }

    // MARK: 数据

    private var canCancel: Bool {
        run.status == "in_progress" || run.status == "queued"
    }

    private var hasActiveJob: Bool {
        ActionFormat.isActive(status: run.status) || jobs.contains { ActionFormat.isActive(status: $0.status) }
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

    private func pollWhileActive() async {
        guard hasActiveJob else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if Task.isCancelled { break }
            await loadJobs()
        }
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

// MARK: - 文案与配色

/// Actions 的状态文案、图标、配色与时间格式。
enum ActionFormat {

    // MARK: 运行

    static func text(for run: GitHubWorkflowRun) -> String {
        text(conclusion: run.conclusion, status: run.status)
    }

    static func color(for run: GitHubWorkflowRun) -> Color {
        color(conclusion: run.conclusion, status: run.status)
    }

    static func symbol(for run: GitHubWorkflowRun) -> String {
        symbol(conclusion: run.conclusion, status: run.status)
    }

    /// 运行是否还在排队 / 进行中。
    static func isActive(status: String?) -> Bool {
        switch status {
        case "in_progress", "queued", "waiting", "requested", "pending": return true
        default: return false
        }
    }

    // MARK: 通用状态

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
        case "queued", "pending": return "排队中"
        case "waiting": return "等待中"
        case "requested": return "已请求"
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

    // MARK: 时间

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
        return isoFormatter.date(from: iso) ?? fractionalFormatter.date(from: iso)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
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
