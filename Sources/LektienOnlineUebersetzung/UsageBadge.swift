import SwiftUI
import PlayerCore
import PlayerTranslation

@MainActor
final class UsageController: ObservableObject {
    @Published private(set) var limits: UsageLimits?
    @Published private(set) var updated: Date?
    @Published private(set) var failed = false
    @Published private(set) var loading = false
    private var lastAttempt: Date?
    private var cancellation: TranslationCancellation?

    func refresh() async {
        guard !loading, lastAttempt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true,
              let executable = CodexClient.installedExecutable() else { return }
        loading = true; lastAttempt = Date()
        let control = TranslationCancellation()
        cancellation = control
        defer { loading = false; cancellation = nil }
        do {
            let value = try await withTaskCancellationHandler {
                try await Task.detached { try UsageLimitsClient.read(executable: executable, cancellation: control) }.value
            } onCancel: { control.cancel() }
            limits = value; updated = Date(); failed = false
        } catch { failed = true }
    }
}

struct UsageBadge: View {
    @ObservedObject var usage: UsageController
    @Binding var expanded: Bool
    private var windows: [UsageWindow] { usage.limits?.buckets.flatMap(\.windows) ?? [] }
    private func window(_ minutes: Int) -> UsageWindow? { windows.first { $0.windowDurationMins == minutes } }
    private func percent(_ minutes: Int) -> String { window(minutes)?.remaining.map { "\($0)%" } ?? "—" }
    var body: some View {
        Button { expanded.toggle() } label: {
            Text("ChatGPT · " + translationText("usage.remaining") + " · " + translationText("usage.fiveHoursShort") + " " + percent(300) + " · " + translationText("usage.week") + " " + percent(10080))
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }.buttonStyle(.plain).help(translationText("usage.help"))
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(translationText("usage.title")).font(.headline)
                    if let plan = usage.limits?.buckets.first?.planType { Text("ChatGPT · " + plan.capitalized).font(.caption) }
                    row(translationText("usage.fiveHours"), window: window(300))
                    row(translationText("usage.week"), window: window(10080))
                    ForEach(Array(windows.filter { $0.windowDurationMins != 300 && $0.windowDurationMins != 10080 }.enumerated()), id: \.offset) { _, item in
                        row(item.windowDurationMins.map { "\($0) " + translationText("time.minutes") } ?? translationText("usage.otherWindow"), window: item)
                    }
                    Text(translationText("usage.help")).font(.caption).foregroundStyle(.secondary)
                    if let date = usage.updated { Text(translationText(usage.failed ? "usage.stale" : "usage.updated") + " " + date.formatted(.dateTime.hour().minute().locale(AppLocalization.locale))).font(.caption2) }
                    if usage.failed { Text(translationText("usage.failed")).font(.caption) }
                    Button(translationText("usage.refresh")) { Task { await usage.refresh() } }.disabled(usage.loading)
                }.padding(18).frame(width: 320)
            }
    }
    @ViewBuilder private func row(_ title: String, window: UsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text(window?.remaining.map { "\($0)% " + translationText("usage.remaining") } ?? translationText("usage.unavailable")).monospacedDigit() }
            if let reset = window?.resetsAt {
                Text(translationText("usage.reset") + " " + Date(timeIntervalSince1970: reset).formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(AppLocalization.locale)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
