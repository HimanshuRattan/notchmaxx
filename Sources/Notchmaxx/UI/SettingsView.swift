import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var store: UsageStore
    var openSetup: () -> Void

    var body: some View {
        Form {
            Section("Accounts") {
                if store.allAccounts.isEmpty {
                    Text("No accounts found yet.").foregroundStyle(.secondary)
                }
                ForEach(store.allAccounts) { account in
                    AccountSettingsRow(account: account, settings: settings)
                }
            }

            Section {
                FolderList(title: "Claude Code config folders", paths: $settings.value.claudeConfigDirs)
                FolderList(title: "Codex homes (CODEX_HOME)", paths: $settings.value.codexHomes)
                Toggle("Cursor", isOn: $settings.value.cursorEnabled)
            } header: {
                Text("Sources")
            } footer: {
                Text("Add a folder for each extra login, for example one made with `CODEX_HOME=~/.codex_team codex login`. Codex accounts used inside other apps also show up from Codex's session logs.")
            }

            Section {
                Toggle("Claude", isOn: $settings.value.liveClaude)
                Toggle("Codex", isOn: $settings.value.liveCodex)
                Toggle("Cursor", isOn: $settings.value.liveCursor)
                Picker("Check every", selection: $settings.value.liveIntervalMinutes) {
                    ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            } header: {
                Text("Live refresh")
            } footer: {
                Text("Uses each tool's existing sign-in, read-only. Tokens are never refreshed or written back. With live refresh off, Claude and Codex still update from local files.")
            }

            Section("Alerts") {
                ForEach([75, 90, 100], id: \.self) { threshold in
                    Toggle("At \(threshold)%", isOn: Binding(
                        get: { settings.value.alertThresholds.contains(threshold) },
                        set: { on in
                            if on { settings.value.alertThresholds.insert(threshold) } else { settings.value.alertThresholds.remove(threshold) }
                        }))
                }
                Toggle("When a window resets", isOn: $settings.value.resetAlerts)
                Toggle("Also send macOS notifications", isOn: Binding(
                    get: { settings.value.systemNotifications },
                    set: { on in
                        settings.value.systemNotifications = on
                        if on { AlertCenter.requestAuthorization() }
                    }))
            }

            Section("Notch") {
                Picker("Show the pill", selection: $settings.value.pillMode) {
                    ForEach(PillMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Menu bar icon", isOn: $settings.value.showMenuBarIcon)
                Toggle("Open at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }))
            }

            Section {
                HStack {
                    Button("Run setup assistant", action: openSetup)
                    Spacer()
                    Button("Refresh now") { Task { await store.refreshAll() } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 640)
    }
}

private struct AccountSettingsRow: View {
    var account: AccountSnapshot
    @Bindable var settings: SettingsStore

    var body: some View {
        HStack(spacing: 12) {
            ProviderGlyph(provider: account.provider, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name", text: Binding(
                    get: { settings.value.accountNames[account.id] ?? "" },
                    set: { settings.value.accountNames[account.id] = $0.isEmpty ? nil : $0 }),
                    prompt: Text(account.name))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                Text([account.subtitle, account.source == .logs ? "from session logs" : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Show", isOn: Binding(
                get: { !settings.value.hiddenAccounts.contains(account.id) },
                set: { show in
                    if show { settings.value.hiddenAccounts.remove(account.id) } else { settings.value.hiddenAccounts.insert(account.id) }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct FolderList: View {
    var title: String
    @Binding var paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button {
                    if let path = pickFolder(), !paths.contains(path) { paths.append(path) }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            ForEach(paths, id: \.self) { path in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(path).font(.system(size: 12, design: .monospaced))
                    if !FileManager.default.fileExists(atPath: path.expandingTilde) {
                        Text("missing").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button {
                        paths.removeAll { $0 == path }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(paths.count == 1)
                }
            }
        }
    }

    private func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
