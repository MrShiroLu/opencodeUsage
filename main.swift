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
    case auto, cost, tokens

    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .cost: return "Cost"
        case .tokens: return "Tokens"
        }
    }
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

func currency(_ value: Double) -> String {
    if value > 0 && value < 0.01 { return "<$0.01" }
    return String(format: "$%.2f", value)
}

// MARK: - Model

final class MeterModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
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
    private let binary = findOpenCode()

    init() {
        period = Period(rawValue: defaults.object(forKey: "period") as? Int ?? 0) ?? .today
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "auto") ?? .auto
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

    /// Used by the offscreen render harness so the design can be checked without a screen recording.
    func preview(_ snapshot: Snapshot, period: Period = .week) {
        isPreviewing = true
        self.period = period
        isPreviewing = false
        self.snapshot = snapshot
        self.error = nil
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

    private func weekday(for date: String) -> String {
        guard let parsed = Self.dayFormatter.date(from: date) else { return "" }
        return Self.weekdayFormatter.string(from: parsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Daily steps")

            GeometryReader { geo in
                let visible = Array(days.suffix(14))
                let gap: CGFloat = 4
                let slot = (geo.size.width - gap * CGFloat(max(visible.count - 1, 0))) / CGFloat(max(visible.count, 1))
                let barWidth = min(max(slot, 2), 16)
                let chartHeight = geo.size.height - 10

                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, day in
                        let isLast = index == visible.count - 1
                        let ratio = Double(day.steps) / Double(maxSteps)
                        let height = day.steps == 0 ? 2 : max(3, chartHeight * CGFloat(ratio))
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 44)
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
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(active ? Color.primary.opacity(0.09) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
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

private struct RefreshGlyph: View {
    let isLoading: Bool

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent)
            .opacity(isLoading ? 0.3 : 1)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isLoading)
    }
}

struct MeterView: View {
    @ObservedObject var model: MeterModel

    private var showsCost: Bool {
        guard let snapshot = model.snapshot else { return false }
        switch model.displayMode {
        case .cost: return true
        case .tokens: return false
        case .auto: return snapshot.cost > 0
        }
    }

    private var headline: String {
        guard let snapshot = model.snapshot else { return "—" }
        return showsCost ? currency(snapshot.cost) : compact(snapshot.totalTokens)
    }

    private var subtitle: String {
        guard let snapshot = model.snapshot else { return model.error ?? "Loading…" }
        var parts: [String] = [showsCost ? "spent" : "tokens"]
        if !showsCost || snapshot.cost == 0 {
            parts.append(currency(snapshot.cost))
        }
        parts.append("\(snapshot.sessions) sessions")
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
        HStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
            Text("OpenCode Meter")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)

            Button {
                model.reopenWelcome()
            } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the welcome screen")

            Button {
                cycleDisplayMode()
            } label: {
                Text(displayGlyph)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(model.displayMode == .auto ? Color.secondary : accent)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(model.displayMode == .auto ? 0.05 : 0.09))
                    )
            }
            .buttonStyle(.plain)
            .help("Menu bar shows: \(model.displayMode.label) — click to switch")

            Button {
                model.refresh()
            } label: {
                RefreshGlyph(isLoading: model.isLoading)
            }
            .buttonStyle(.plain)
            .help("Refresh now")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quit OpenCode Meter")
        }
    }

    private var displayGlyph: String {
        switch model.displayMode {
        case .auto: return "A"
        case .cost: return "$"
        case .tokens: return "#"
        }
    }

    private func cycleDisplayMode() {
        switch model.displayMode {
        case .auto: model.displayMode = .cost
        case .cost: model.displayMode = .tokens
        case .tokens: model.displayMode = .auto
        }
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
        let peak = max(snapshot.input, snapshot.output, snapshot.reasoning, 1)
        return Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Tokens")
                TokenBar(label: "Input", value: snapshot.input, maxValue: peak)
                TokenBar(label: "Output", value: snapshot.output, maxValue: peak)
                TokenBar(label: "Reasoning", value: snapshot.reasoning, maxValue: peak)
                if snapshot.cacheTokens > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.horizontal.circle")
                            .font(.system(size: 9))
                        Text("cache \(compact(snapshot.cacheTokens))")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
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
            StatChip(value: "\(snapshot.sessions)", label: "sessions")
            StatChip(value: compact(snapshot.steps), label: "steps")
            StatChip(value: "\(snapshot.prompts)", label: "prompts")
            StatChip(value: "\(snapshot.toolCalls)", label: "tools")
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
            footnote
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
            Text("Your OpenCode usage, right in the menu bar.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 9) {
            FeatureRow(
                symbol: "chart.bar.fill",
                title: "Cost and tokens at a glance",
                detail: "Daily spend, token split, top models and activity."
            )
            FeatureRow(
                symbol: "lock.fill",
                title: "Reads your Mac, nothing else",
                detail: "Powered by opencode stats. No account, no API key, no network calls."
            )
            FeatureRow(
                symbol: "clock.arrow.circlepath",
                title: "Always current",
                detail: "Refreshes every minute and whenever you open it."
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

    private var footnote: some View {
        Text("Everything stays on this Mac.")
            .font(.system(size: 8.5))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var model = MeterModel()
    private var host: NSHostingController<MeterView>!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "OpenCode usage")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }

        host = NSHostingController(rootView: MeterView(model: model))
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
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
        guard statusItem.button != nil else { return }
        var text = "!"
        if let snapshot = model.snapshot, model.error == nil {
            switch model.displayMode {
            case .cost:
                text = currency(snapshot.cost)
            case .tokens:
                text = compact(snapshot.totalTokens)
            case .auto:
                text = snapshot.cost > 0 ? currency(snapshot.cost) : compact(snapshot.totalTokens)
            }
        }
        setTitle(text)
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
        popover.contentSize = NSSize(width: 336, height: min(max(fitting.height, 260), 620))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        resizePopover()
    }
}

// MARK: - Entry point

@MainActor
func renderPreview(to path: String) -> Int32 {
    let renderModel = MeterModel()
    var loaded: Snapshot?
    if let binary = findOpenCode(), case .success(let snapshot) = runStats(binary: binary, period: .week) {
        loaded = snapshot
    }
    if ProcessInfo.processInfo.environment["OCMETER_DEMO"] == "1", var demo = loaded {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let pattern = [42, 96, 18, 130, 74, 155, 61, 88, 12, 143, 99, 57, 120, 31]
        demo.activity = (0..<14).compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: offset - 13, to: Date()) else { return nil }
            return DayActivity(date: formatter.string(from: date), steps: pattern[offset])
        }
        loaded = demo
    }
    if let snapshot = loaded {
        renderModel.preview(snapshot, period: ProcessInfo.processInfo.environment["OCMETER_DEMO"] == "1" ? .month : .week)
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
