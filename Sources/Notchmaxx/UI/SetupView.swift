import SwiftUI

struct SetupView: View {
    var store: UsageStore
    var openSettings: () -> Void
    var done: () -> Void
    @StateObject private var checking = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Notchmaxx")
                    .font(.system(size: 24, weight: .semibold))
                Text("It reads the sign-ins your coding tools already have, read-only, and shows their limits in the notch. Hover the notch to open it.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(Provider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    ProviderCheckRow(provider: provider, accounts: store.allAccounts.filter { $0.provider == provider },
                                     scanned: store.hasScanned, issue: provider == .codex ? store.codexIssue : nil)
                        .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.2")
                    .foregroundStyle(Theme.accent(.codex))
                Text("More than one Codex account? Accounts you use anywhere, including T3 Code, appear from Codex's session logs. For live numbers and manual resets, sign the extra account in to its own folder with `CODEX_HOME=~/.codex_team codex login` and add that folder in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button {
                    checking.value = true
                    Task {
                        await store.refreshAll()
                        checking.value = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if checking.value { ProgressView().controlSize(.small) }
                        Text("Check again")
                    }
                }
                Spacer()
                Button("Settings", action: openSettings)
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560, height: 600)
        .background(Color(red: 0.045, green: 0.045, blue: 0.05))
        .environment(\.colorScheme, .dark)
    }
}

private struct ProviderCheckRow: View {
    var provider: Provider
    var accounts: [AccountSnapshot]
    var scanned: Bool
    var issue: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProviderGlyph(provider: provider, size: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(provider.name)
                    .font(.system(size: 14, weight: .semibold))
                if accounts.isEmpty {
                    Text(scanned ? LocalizedStringKey(missingText) : "Checking…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(accounts) { account in
                    Text(line(for: account))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            statusIcon
        }
    }

    private var statusIcon: some View {
        let ok = accounts.contains { !$0.windows.isEmpty }
        let partial = !accounts.isEmpty && !ok
        return Image(systemName: ok ? "checkmark.circle.fill" : (partial ? "exclamationmark.circle.fill" : "circle.dashed"))
            .font(.system(size: 18))
            .foregroundStyle(ok ? Theme.good : (partial ? Theme.warn : Theme.tertiary))
    }

    private func line(for account: AccountSnapshot) -> String {
        var parts = [account.name]
        if !account.subtitle.isEmpty { parts.append(account.subtitle) }
        if account.source == .logs { parts.append("from session logs") }
        if account.windows.isEmpty, let error = account.error { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private var missingText: String {
        if let issue { return issue }
        return switch provider {
        case .claude: "Not signed in. Run `claude` and log in."
        case .codex: "Not signed in. Run `codex login`."
        case .cursor: CursorSource.isInstalled ? "Installed, but no usage yet." : "Not installed."
        }
    }
}
