import AppKit
import Combine
import SwiftUI

// MARK: - Period

enum Period: Int, CaseIterable, Hashable {
    case today = 0
    case week = 7
    case month = 30
    case all = -1

    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .all: return "All time"
        }
    }

    var shortLabel: String {
        switch self {
        case .today: return "Today"
        case .week: return "7d"
        case .month: return "30d"
        case .all: return "All"
        }
    }

    func arguments() -> [String] {
        switch self {
        case .all: return ["--all"]
        default: return ["--days", String(rawValue)]
        }
    }
}

// MARK: - Display mode

enum DisplayMode: String, CaseIterable, Hashable {
    case tokens, logo

    var label: String {
        switch self {
        case .tokens: return "Tokens"
        case .logo: return "Logo"
        }
    }

    var shortLabel: String { label }
}

// MARK: - Snapshot

struct ModelRow: Identifiable {
    let id = UUID()
    let name: String
    let tokens: Int
    let cost: Double
    let steps: Int
}

struct DayActivity: Identifiable {
    var id: String { date }
    let date: String
    let steps: Int
}

struct UsageWindow: Identifiable {
    let id: String
    let title: String
    let percent: Int
    let limited: Bool
    let resetsAt: Date
}

struct UsageLimits {
    var windows: [UsageWindow] = []
    var dashboardURL: URL?
}

struct Snapshot {
    var cost: Double = 0
    var input: Int = 0
    var output: Int = 0
    var reasoning: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var sessions: Int = 0
    var subagents: Int = 0
    var prompts: Int = 0
    var steps: Int = 0
    var activeDays: Int = 0
    var streak: Int = 0
    var toolCalls: Int = 0
    var toolFailed: Int = 0
    var models: [ModelRow] = []
    var activity: [DayActivity] = []
    var raw: String = ""

    var totalTokens: Int { input + output + reasoning }
    var cacheTokens: Int { cacheRead + cacheWrite }
}

// MARK: - Stats runner

enum StatsError: LocalizedError {
    case binaryNotFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "opencode not found"
        case .failed(let message): return message
        }
    }
}

func findOpenCode() -> String? {
    let candidates = [
        "/opt/homebrew/bin/opencode",
        "/usr/local/bin/opencode",
        NSHomeDirectory() + "/.bun/bin/opencode",
        NSHomeDirectory() + "/.local/bin/opencode",
        "/usr/bin/opencode",
    ]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    // Login shell fallback so nvm/asdf style installs are still found.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "command -v opencode"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
    } catch {}
    return nil
}

func runStats(binary: String, period: Period) -> Result<Snapshot, Error> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["stats"] + period.arguments() + ["--cost", "--json"]

    var environment = ProcessInfo.processInfo.environment
    let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    environment["PATH"] = (extraPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        return .failure(StatsError.failed(error.localizedDescription))
    }

    // Watchdog: stats should be fast; never hang the popover.
    let watchdog = DispatchWorkItem {
        if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: watchdog)

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()

    guard process.terminationStatus == 0 else {
        let message = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(StatsError.failed(message.isEmpty ? "opencode stats failed (exit \(process.terminationStatus))" : message))
    }

    guard let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any] else {
        return .failure(StatsError.failed("Could not parse stats JSON"))
    }

    var snapshot = Snapshot()
    snapshot.raw = String(decoding: data, as: UTF8.self)
    snapshot.cost = number(root["cost"])
    snapshot.sessions = int(root["sessions"])
    snapshot.subagents = int(root["subagents"])
    snapshot.prompts = int(root["prompts"])
    snapshot.steps = int(root["steps"])
    snapshot.activeDays = int(root["activeDays"])
    snapshot.streak = int(root["streak"])

    if let tokens = root["tokens"] as? [String: Any] {
        snapshot.input = int(tokens["input"])
        snapshot.output = int(tokens["output"])
        snapshot.reasoning = int(tokens["reasoning"])
        if let cache = tokens["cache"] as? [String: Any] {
            snapshot.cacheRead = int(cache["read"])
            snapshot.cacheWrite = int(cache["write"])
        }
    }

    if let tools = root["tools"] as? [String: Any],
       let totals = tools["totals"] as? [String: Any] {
        snapshot.toolCalls = int(totals["calls"])
        snapshot.toolFailed = int(totals["failed"])
    }

    if let activity = root["activity"] as? [[String: Any]] {
        snapshot.activity = activity.compactMap { entry in
            guard let date = entry["date"] as? String else { return nil }
            return DayActivity(date: date, steps: int(entry["steps"]))
        }
    }

    if let models = root["models"] as? [[String: Any]] {
        snapshot.models = models.compactMap { entry in
            guard let model = entry["model"] as? [String: Any] else { return nil }
            let id = (model["id"] as? String) ?? "unknown"
            let provider = (model["providerID"] as? String) ?? ""
            var tokens = 0
            if let t = entry["tokens"] as? [String: Any] {
                tokens = int(t["input"]) + int(t["output"]) + int(t["reasoning"])
            }
            let name = provider == "opencode" ? id : "\(id) · \(provider)"
            return ModelRow(
                name: name,
                tokens: tokens,
                cost: number(entry["cost"]),
                steps: int(entry["steps"])
            )
        }
        .sorted { $0.tokens > $1.tokens }
    }

    return .success(snapshot)
}

func fetchLimits(binary: String) -> Result<UsageLimits, Error> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["api", "get", "/api/experimental/usage/limits"]

    var environment = ProcessInfo.processInfo.environment
    let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    environment["PATH"] = (extraPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        return .failure(StatsError.failed(error.localizedDescription))
    }

    let watchdog = DispatchWorkItem {
        if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()

    guard process.terminationStatus == 0 else {
        let message = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(StatsError.failed(message.isEmpty ? "usage limits unavailable" : message))
    }

    guard let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any],
          let payload = root["data"] as? [String: Any] else {
        return .failure(StatsError.failed("unexpected limits response"))
    }

    var limits = UsageLimits()
    if let workspace = payload["workspace"] as? [String: Any],
       let urlString = workspace["usageURL"] as? String {
        limits.dashboardURL = URL(string: urlString)
    }

    if let go = payload["go"] as? [String: Any] {
        let windows: [(String, String, String)] = [
            ("rolling", "5 hours", "rolling"),
            ("weekly", "Week", "weekly"),
            ("monthly", "Month", "monthly"),
        ]
        for (key, title, id) in windows {
            guard let entry = go[key] as? [String: Any] else { continue }
            let resetsAt = Date(timeIntervalSince1970: number(entry["resetsAt"]) / 1000)
            limits.windows.append(
                UsageWindow(
                    id: id,
                    title: title,
                    percent: int(entry["percent"]),
                    limited: (entry["limited"] as? Bool) ?? false,
                    resetsAt: resetsAt
                )
            )
        }
    }

    return .success(limits)
}

func int(_ value: Any?) -> Int {
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String, let n = Int(s) { return n }
    return 0
}

func number(_ value: Any?) -> Double {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String, let n = Double(s) { return n }
    return 0
}

// MARK: - Formatting

func compact(_ value: Int) -> String {
    let d = Double(value)
    switch value {
    case ..<0: return "0"
    case 0..<1_000: return "\(value)"
    case 1_000..<1_000_000: return String(format: "%.0fK", d / 1_000)
    case 1_000_000..<1_000_000_000: return String(format: "%.1fM", d / 1_000_000)
    default: return String(format: "%.1fB", d / 1_000_000_000)
    }
}

func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func currency(_ value: Double) -> String {
    if value > 0 && value < 0.01 { return "<$0.01" }
    return String(format: "$%.2f", value)
}

func countdown(to date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSinceNow))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

// MARK: - Model

final class MeterModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var limits: UsageLimits?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdate: Date?
    @Published var period: Period {
        didSet {
            guard !isPreviewing else { return }
            UserDefaults.standard.set(period.rawValue, forKey: "period")
            resetAndLoad()
        }
    }
    @Published var displayMode: DisplayMode {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode") }
    }
    @Published var showWelcome: Bool

    var openCodePath: String? { binary }

    var isOnboarded: Bool { defaults.bool(forKey: "hasOnboarded") }

    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var pendingRefresh = false
    private var isPreviewing = false
    private var lastLimitsFetch: Date?
    private var isLoadingLimits = false
    private let binary = findOpenCode()

    init() {
        period = Period(rawValue: defaults.object(forKey: "period") as? Int ?? 0) ?? .today
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .tokens
        // Earlier builds stored "emoji" for the icon-only mode.
        if defaults.string(forKey: "displayMode") == "emoji" { displayMode = .logo }
        showWelcome = !defaults.bool(forKey: "hasOnboarded")
    }

    func completeOnboarding() {
        defaults.set(true, forKey: "hasOnboarded")
        showWelcome = false
        refresh()
    }

    func reopenWelcome() {
        showWelcome = true
    }

    func start() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard let binary else {
            error = "opencode not found"
            onChange?()
            return
        }
        if isLoading {
            pendingRefresh = true
            return
        }
        isLoading = true
        onChange?()
        refreshLimits()

        let requested = period
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = runStats(binary: binary, period: requested)
            DispatchQueue.main.async {
                guard let self else { return }
                guard requested == self.period else {
                    self.isLoading = false
                    if self.pendingRefresh {
                        self.pendingRefresh = false
                        self.refresh()
                    }
                    return
                }
                self.isLoading = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.error = nil
                case .failure(let error):
                    self.error = error.localizedDescription
                }
                self.lastUpdate = Date()
                self.onChange?()
            }
        }
    }

    private func resetAndLoad() {
        snapshot = nil
        error = nil
        onChange?()
        refresh()
    }

    func refreshLimits(force: Bool = false) {
        guard let binary else { return }
        if !force, let last = lastLimitsFetch, Date().timeIntervalSince(last) < 300 { return }
        if isLoadingLimits { return }
        isLoadingLimits = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = fetchLimits(binary: binary)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingLimits = false
                self.lastLimitsFetch = Date()
                if case .success(let limits) = result, !limits.windows.isEmpty {
                    self.limits = limits
                }
                self.onChange?()
            }
        }
    }

    /// Used by the offscreen render harness so the design can be checked without a screen recording.
    func preview(_ snapshot: Snapshot, period: Period = .week, limits: UsageLimits? = nil) {
        isPreviewing = true
        self.period = period
        isPreviewing = false
        self.snapshot = snapshot
        self.error = nil
        self.limits = limits
        self.lastUpdate = Date()
    }
}

// MARK: - Components

private let accent = Color(nsColor: .controlAccentColor)

struct TokenBar: View {
    let label: String
    let value: Int
    let maxValue: Int

    private var fraction: Double {
        guard maxValue > 0 else { return 0 }
        return min(1, Double(value) / Double(maxValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(compact(value))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.95), accent.opacity(0.55)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
    }
}

struct ActivityChart: View {
    let days: [DayActivity]

    private var maxSteps: Int { max(days.map(\.steps).max() ?? 0, 1) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter
    }()

    private static let axisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private func weekday(for date: String) -> String {
        guard let parsed = Self.dayFormatter.date(from: date) else { return "" }
        return Self.weekdayFormatter.string(from: parsed)
    }

    private func axisDate(for date: String) -> String {
        guard let parsed = Self.dayFormatter.date(from: date) else { return date }
        return Self.axisFormatter.string(from: parsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                SectionLabel(text: "Daily steps")
                Spacer()
                Text("total \(compact(days.map(\.steps).reduce(0, +)))")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.quaternary)
            }

            HStack(spacing: 5) {
                // Y axis
                VStack(spacing: 0) {
                    Text(compact(maxSteps))
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.quaternary)
                        .frame(height: 7, alignment: .top)
                    Spacer(minLength: 0)
                    Text("0")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.quaternary)
                        .frame(height: 7, alignment: .bottom)
                }
                .frame(width: 16)

                GeometryReader { geo in
                    let visible = Array(days.suffix(14))
                    let gap: CGFloat = 4
                    let slot = (geo.size.width - gap * CGFloat(max(visible.count - 1, 0))) / CGFloat(max(visible.count, 1))
                    let barWidth = min(max(slot, 2), 16)

                    ZStack(alignment: .bottomLeading) {
                        // baseline
                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 0.5)

                        HStack(alignment: .bottom, spacing: gap) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, day in
                                let isLast = index == visible.count - 1
                                let ratio = Double(day.steps) / Double(maxSteps)
                                let height = day.steps == 0 ? 2 : max(3, (geo.size.height - 8) * CGFloat(ratio))
                                VStack(spacing: 3) {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(
                                            day.steps == 0
                                                ? AnyShapeStyle(Color.primary.opacity(0.08))
                                                : AnyShapeStyle(
                                                    LinearGradient(
                                                        colors: [
                                                            accent.opacity(isLast ? 0.95 : 0.7),
                                                            accent.opacity(isLast ? 0.6 : 0.35),
                                                        ],
                                                        startPoint: .top,
                                                        endPoint: .bottom
                                                    )
                                                )
                                        )
                                        .frame(width: barWidth, height: height)
                                    Text(weekday(for: day.date))
                                        .font(.system(size: 7, weight: .medium))
                                        .foregroundStyle(.quaternary)
                                        .frame(height: 7)
                                }
                                .frame(maxWidth: .infinity)
                                .help("\(day.date) · \(day.steps) steps")
                            }
                        }
                    }
                }
                .frame(height: 44)
            }

            // X axis
            HStack(spacing: 5) {
                Spacer().frame(width: 16)
                if let first = days.first, let last = days.last {
                    Text(axisDate(for: first.date))
                    Spacer()
                    Text(axisDate(for: last.date))
                }
            }
            .font(.system(size: 7, weight: .medium))
            .foregroundStyle(.quaternary)
        }
    }
}

struct LimitRow: View {
    let window: UsageWindow

    private var barColor: Color {
        if window.limited || window.percent >= 95 { return .red }
        if window.percent >= 80 { return .orange }
        return accent
    }

    private var clamped: Double {
        min(max(Double(window.percent), 0), 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(window.title)
                    .font(.system(size: 10, weight: .medium))
                if window.limited {
                    Text("limit reached")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.12)))
                }
                Spacer(minLength: 4)
                Text("\(window.percent)%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(barColor)
                Text("resets in \(countdown(to: window.resetsAt))")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(barColor.opacity(0.85))
                        .frame(width: max(2, geo.size.width * CGFloat(clamped / 100)))
                }
            }
            .frame(height: 4)
        }
    }
}

struct ModelRowView: View {
    let row: ModelRow
    let maxTokens: Int

    private var fraction: Double {
        guard maxTokens > 0 else { return 0 }
        return min(1, Double(row.tokens) / Double(maxTokens))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(compact(row.tokens))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(accent.opacity(0.55))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
        }
    }
}

private struct StatChip: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Popover view

private struct SegmentedControl: View {
    @Binding var selection: Period

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Period.allCases, id: \.self) { option in
                let active = option == selection
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selection = option }
                } label: {
                    Text(option.shortLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        // Clear fills are not hit-testable. Define the hit area explicitly
                        // so the whole segment, not just the label text, responds.
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(active ? Color.primary.opacity(0.09) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(.tertiary)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }
}

/// Small icon+label pill. The text states what the button does.
private struct ActionPill: View {
    let symbol: String
    let label: String
    var tint: Color = .secondary
    var active = false
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(active ? accent : tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(minHeight: 20)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(active || hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .ifLet(help) { view, tip in view.help(tip) }
    }
}

extension View {
    @ViewBuilder
    func ifLet<T, Transformed: View>(_ value: T?, transform: (Self, T) -> Transformed) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

struct MeterView: View {
    @ObservedObject var model: MeterModel

    private var headline: String {
        guard let snapshot = model.snapshot else { return "…" }
        return compact(snapshot.totalTokens)
    }

    private var subtitle: String {
        guard let snapshot = model.snapshot else { return model.error ?? "Loading…" }
        var parts: [String] = ["tokens", currency(snapshot.cost), "\(snapshot.sessions) sessions"]
        if snapshot.streak > 1 {
            parts.append("\(snapshot.streak)-day streak")
        }
        return parts.joined(separator: " · ")
    }

    private var timeString: String {
        guard let date = model.lastUpdate else { return "never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    var body: some View {
        Group {
            if model.showWelcome {
                WelcomeView(model: model)
            } else {
                dashboard
            }
        }
        .frame(width: 336)
        .background(.regularMaterial)
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let limits = model.limits, !limits.windows.isEmpty {
                limitsCard(limits)
            }
            VStack(alignment: .leading, spacing: 10) {
                headlineBlock
                SegmentedControl(selection: $model.period)
            }
            content
            footer
        }
        .padding(16)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
            Text("OpenCode")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 2)
            Spacer(minLength: 4)

            ActionPill(
                symbol: "questionmark.circle",
                label: "Help",
                help: "Show the welcome screen"
            ) {
                model.reopenWelcome()
            }

            ActionPill(
                symbol: "chevron.left.forwardslash.chevron.right",
                label: model.displayMode.shortLabel,
                active: model.displayMode == .logo,
                help: "Change what the menu bar shows"
            ) {
                cycleDisplayMode()
            }

            ActionPill(
                symbol: "arrow.clockwise",
                label: "Refresh",
                tint: model.isLoading ? .secondary.opacity(0.45) : accent,
                help: "Refresh now"
            ) {
                model.refresh()
            }

            ActionPill(
                symbol: "power",
                label: "Quit",
                tint: .secondary.opacity(0.8),
                help: "Quit OpenCode Meter"
            ) {
                NSApp.terminate(nil)
            }
        }
    }

    private func limitsCard(_ limits: UsageLimits) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 4) {
                    SectionLabel(text: "Limits")
                    Spacer()
                    if let url = limits.dashboardURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Text("Open dashboard")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Open the OpenCode usage dashboard")
                    }
                }
                ForEach(limits.windows) { window in
                    LimitRow(window: window)
                }
            }
        }
    }

    private func cycleDisplayMode() {
        model.displayMode = model.displayMode == .tokens ? .logo : .tokens
    }

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.22), value: headline)
            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: 14) {
                tokenCard(snapshot)

                let series = paddedActivity(snapshot)
                if series.filter({ $0.steps > 0 }).count >= 2 {
                    ActivityChart(days: series)
                }

                if !snapshot.models.isEmpty {
                    modelSection(snapshot)
                }

                statRow(snapshot)
            }
        } else {
            VStack(spacing: 8) {
                if model.isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("Reading local stats…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.error ?? "No data yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    private func tokenCard(_ snapshot: Snapshot) -> some View {
        let peak = max(snapshot.input, snapshot.output, snapshot.reasoning, snapshot.cacheTokens, 1)
        return Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Tokens")
                TokenBar(label: "Input", value: snapshot.input, maxValue: peak)
                TokenBar(label: "Output", value: snapshot.output, maxValue: peak)
                TokenBar(label: "Reasoning", value: snapshot.reasoning, maxValue: peak)
                if snapshot.cacheTokens > 0 {
                    TokenBar(label: "Cache", value: snapshot.cacheTokens, maxValue: snapshot.cacheTokens)
                }
            }
        }
    }

    private func modelSection(_ snapshot: Snapshot) -> some View {
        let peak = max(snapshot.models.first?.tokens ?? 1, 1)
        return VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Models")
            ForEach(Array(snapshot.models.prefix(3).enumerated()), id: \.element.id) { _, row in
                ModelRowView(row: row, maxTokens: peak)
            }
        }
        .padding(.horizontal, 2)
    }

    private func statRow(_ snapshot: Snapshot) -> some View {
        HStack(spacing: 0) {
            StatChip(value: grouped(snapshot.sessions), label: "sessions")
            StatChip(value: grouped(snapshot.steps), label: "steps")
            StatChip(value: grouped(snapshot.prompts), label: "prompts")
            StatChip(value: grouped(snapshot.toolCalls), label: "tools")
        }
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.error == nil ? Color.green.opacity(0.8) : Color.orange)
                .frame(width: 4, height: 4)
            Text("Updated \(timeString)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(model.period.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    /// Fills days without activity with zeros so the chart has a real time axis.
    private func paddedActivity(_ snapshot: Snapshot) -> [DayActivity] {
        let byDate = Dictionary(snapshot.activity.map { ($0.date, $0.steps) }, uniquingKeysWith: { first, _ in first })
        let window: Int
        switch model.period {
        case .today, .week: window = 7
        case .month, .all: window = 14
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var days: [DayActivity] = []
        for offset in stride(from: window - 1, through: 0, by: -1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = formatter.string(from: date)
            days.append(DayActivity(date: key, steps: byDate[key] ?? 0))
        }
        return days
    }
}

// MARK: - Welcome

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accent.opacity(0.10))
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StatusRow: View {
    let label: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(label)
                .font(.system(size: 10, weight: .medium))
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: MeterModel
    @State private var copied = false

    private var cliInstalled: Bool { model.openCodePath != nil }
    private var sessions: Int { model.snapshot?.sessions ?? 0 }

    var body: some View {
        VStack(spacing: 14) {
            mark
            heading
            features
            status
            if !cliInstalled { installHint }
            cta
        }
        .padding(20)
    }

    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent, accent.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 52, height: 52)
                .shadow(color: accent.opacity(0.25), radius: 8, y: 3)
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.top, 2)
    }

    private var heading: some View {
        VStack(spacing: 3) {
            Text("OpenCode Meter")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text("OpenCode usage in your menu bar.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 9) {
            FeatureRow(
                symbol: "chart.bar.fill",
                title: "Daily spend and tokens",
                detail: "Cost, token split, models and activity."
            )
            FeatureRow(
                symbol: "lock.fill",
                title: "Local only",
                detail: "Data comes from opencode stats on this Mac. No account, no API key."
            )
            FeatureRow(
                symbol: "clock.arrow.circlepath",
                title: "Auto refresh",
                detail: "Updates every 60 seconds and when you open it."
            )
        }
    }

    private var status: some View {
        Card {
            VStack(spacing: 7) {
                StatusRow(
                    label: "OpenCode CLI",
                    value: cliInstalled ? shortPath : "not found",
                    ok: cliInstalled
                )
                StatusRow(
                    label: "Local usage",
                    value: sessions > 0 ? "\(sessions) sessions" : "no data yet",
                    ok: sessions > 0
                )
            }
        }
    }

    private var shortPath: String {
        guard let path = model.openCodePath else { return "not found" }
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var installHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OpenCode is not installed yet. After installing it, use it once so there is data to read.")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("brew install opencode")
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                Button(copied ? "Copied" : "Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("brew install opencode", forType: .string)
                    copied = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(accent)
            }
        }
    }

    private var cta: some View {
        Button {
            model.completeOnboarding()
        } label: {
            Text(model.isOnboarded ? "Back to dashboard" : "Get started")
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var chartImage: NSImage!
    private var logoImage: NSImage!
    private var popover: NSPopover!
    private var model = MeterModel()
    private var host: NSHostingController<MeterView>!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chartImage = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "OpenCode usage")
        chartImage?.isTemplate = true
        let logoConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        logoImage = NSImage(
            systemSymbolName: "chevron.left.forwardslash.chevron.right",
            accessibilityDescription: "OpenCode Meter"
        )?.withSymbolConfiguration(logoConfig)
        logoImage?.isTemplate = true
        if let button = statusItem.button {
            button.image = chartImage
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }

        host = NSHostingController(rootView: MeterView(model: model))
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 336, height: 430)

        model.onChange = { [weak self] in
            self?.updateTitle()
            self?.resizePopover()
        }
        model.$showWelcome
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizePopover() }
            }
            .store(in: &cancellables)
        model.start()

        setTitle("…")
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        guard let snapshot = model.snapshot, model.error == nil else {
            button.image = chartImage
            setTitle("!")
            return
        }
        switch model.displayMode {
        case .tokens:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = chartImage
            setTitle(compact(snapshot.totalTokens))
        case .logo:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = logoImage
        }
    }

    private func setTitle(_ text: String) {
        guard let button = statusItem.button else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        ]
        button.attributedTitle = NSAttributedString(string: " " + text, attributes: attributes)
    }

    private func resizePopover() {
        let fitting = host.view.fittingSize
        guard fitting.height > 0 else { return }
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        let height = min(max(fitting.height, 260), max(available, 320))
        popover.contentSize = NSSize(width: 336, height: height)
    }

    /// NSPopover grows around the centre of its window when the content gets
    /// taller, which can push the top edge above the menu bar and hide the
    /// header. Pin the top edge back under the menu bar after such a resize.
    @objc private func pinPopoverTop() {
        guard let screen = NSScreen.main,
              let window = host.view.window,
              window.isVisible else { return }
        var frame = window.frame
        let top = screen.visibleFrame.maxY
        guard abs(frame.maxY - top) > 0.5 else { return }
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        resizePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = host.view.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pinPopoverTop),
                name: NSWindow.didResizeNotification,
                object: window
            )
        }
        popover.contentViewController?.view.window?.makeKey()
    }
}

extension AppDelegate {
    func popoverDidClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResizeNotification,
            object: nil
        )
    }
}

// MARK: - Entry point

/// Fixed sample data for the README screenshots, so the published images do not
/// contain real usage numbers.
func demoSnapshot() -> Snapshot {
    var snapshot = Snapshot()
    snapshot.cost = 18.42
    snapshot.input = 12_480_000
    snapshot.output = 486_000
    snapshot.reasoning = 312_000
    snapshot.cacheRead = 38_900_000
    snapshot.cacheWrite = 2_310_000
    snapshot.sessions = 128
    snapshot.subagents = 34
    snapshot.prompts = 942
    snapshot.steps = 5_120
    snapshot.activeDays = 24
    snapshot.streak = 6
    snapshot.toolCalls = 3_891
    snapshot.toolFailed = 12
    snapshot.models = [
        ModelRow(name: "sonnet-4.5 · anthropic", tokens: 5_600_000, cost: 8.90, steps: 2_104),
        ModelRow(name: "gpt-5.1-codex · openai", tokens: 4_400_000, cost: 5.70, steps: 1_780),
        ModelRow(name: "gemini-3-pro · google", tokens: 3_200_000, cost: 3.82, steps: 1_236),
    ]

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let pattern = [142, 96, 18, 230, 174, 355, 261, 188, 112, 343, 199, 57, 220, 131]
    snapshot.activity = (0..<14).compactMap { offset in
        guard let date = Calendar.current.date(byAdding: .day, value: offset - 13, to: Date()) else {
            return nil
        }
        return DayActivity(date: formatter.string(from: date), steps: pattern[offset])
    }
    return snapshot
}

func demoLimits() -> UsageLimits {
    let now = Date()
    return UsageLimits(
        windows: [
            UsageWindow(id: "rolling", title: "5 hours", percent: 42, limited: false,
                        resetsAt: now.addingTimeInterval(2 * 3_600 + 40 * 60)),
            UsageWindow(id: "weekly", title: "Week", percent: 84, limited: false,
                        resetsAt: now.addingTimeInterval(4 * 86_400 + 12 * 3_600)),
            UsageWindow(id: "monthly", title: "Month", percent: 31, limited: false,
                        resetsAt: now.addingTimeInterval(21 * 86_400 + 5 * 3_600)),
        ],
        dashboardURL: URL(string: "https://opencode.ai")
    )
}

@MainActor
func renderPreview(to path: String) -> Int32 {
    let renderModel = MeterModel()
    if ProcessInfo.processInfo.environment["OCMETER_DEMO"] == "1" {
        renderModel.preview(demoSnapshot(), period: .month, limits: demoLimits())
    } else if let binary = findOpenCode(),
              case .success(let snapshot) = runStats(binary: binary, period: .week) {
        let limits: UsageLimits? = {
            guard case .success(let limits) = fetchLimits(binary: binary) else { return nil }
            return limits
        }()
        renderModel.preview(snapshot, period: .week, limits: limits)
    }
    if ProcessInfo.processInfo.environment["OCMETER_WELCOME"] == "1" {
        renderModel.showWelcome = true
    } else {
        renderModel.showWelcome = false
    }
    let renderer = ImageRenderer(
        content: MeterView(model: renderModel)
            .background(Color(nsColor: .windowBackgroundColor))
    )
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("render failed")
        return 1
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("rendered \(path)")
        return 0
    } catch {
        print("render failed: \(error.localizedDescription)")
        return 1
    }
}

// Headless design check: OCMETER_RENDER=/tmp/meter.png ./OpenCodeMeter writes a PNG of the popover.
if let renderPath = ProcessInfo.processInfo.environment["OCMETER_RENDER"] {
    exit(MainActor.assumeIsolated { renderPreview(to: renderPath) })
}

// Headless smoke test: OCMETER_PRINT=1 ./OpenCodeMeter prints one snapshot and exits.
if ProcessInfo.processInfo.environment["OCMETER_PRINT"] == "1" {
    guard let binary = findOpenCode() else {
        print("opencode not found")
        exit(1)
    }
    switch runStats(binary: binary, period: .today) {
    case .success(let snapshot):
        print("cost=\(currency(snapshot.cost)) tokens=\(compact(snapshot.totalTokens)) sessions=\(snapshot.sessions) models=\(snapshot.models.count)")
    case .failure(let error):
        print("error: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
