import SwiftUI

/// "Stremio Account" card at the top of Settings: sign in, sync status, sync now, sign out. OWNER: Stremio Agent 5.
struct StremioAccountCard: View {
    @Environment(StremioAccount.self) private var account
    @Environment(AddonSync.self) private var addonSync
    @Environment(SyncCoordinator.self) private var sync
    @State private var signingIn = false
    @State private var choosingFirstSync = false
    @State private var confirmingSignOut = false
    @State private var isSigningOut = false

    var body: some View {
        SettingsCard(title: "Stremio Account", systemImage: "person.crop.circle.fill", footer: footer) {
            if let user = account.user, account.isSignedIn {
                signedIn(user)
            } else {
                signedOut
            }
        }
        .animation(Theme.Motion.content, value: account.isSignedIn)
        .animation(Theme.Motion.appear, value: sync.lastError)
        .sheet(isPresented: $signingIn) { StremioSignInSheet() }
        .sheet(isPresented: $choosingFirstSync) {
            ScrollView {
                FirstSyncChoiceView { choosingFirstSync = false }
                    .padding(.horizontal, SettingsMetrics.pageGutter)
                    .padding(.vertical, Theme.Space.xl)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
            }
            .dsCanvas()
            #if os(macOS)
            .frame(width: 520)
            #endif
        }
        .confirmationDialog("Sign out of Stremio?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                isSigningOut = true
                Task {
                    await sync.signOut()
                    isSigningOut = false
                }
            }
        } message: {
            Text("Your addons, saved titles and watch progress stay on this device, but they stop syncing with your Stremio account.")
        }
    }

    private var footer: String? {
        account.isSignedIn ? nil : "Optional. DeStream works fully without an account."
    }

    @ViewBuilder
    private var signedOut: some View {
        SettingsRow(title: account.sessionExpired ? "Signed out" : "Not signed in",
                    detail: "Sync your addons, library and watch progress with Stremio.",
                    divider: false) {
            Button(account.sessionExpired ? "Sign In Again" : "Sign In") { signingIn = true }
                .buttonStyle(.ds(.accent, compact: true))
        }
        if account.sessionExpired {
            StatusLine(kind: .warning, text: "Your Stremio session expired, so syncing stopped. Sign in again to resume. Everything on this device is kept.")
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func signedIn(_ user: StremioUser) -> some View {
        HStack(spacing: Theme.Space.m) {
            AccountAvatar(user: user)
            VStack(alignment: .leading, spacing: 3) {
                Text(user.fullname?.isEmpty == false ? user.fullname! : user.email)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if user.fullname?.isEmpty == false {
                    Text(user.email)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                SyncStatusText()
            }
            Spacer(minLength: Theme.Space.m)
        }
        .padding(.bottom, Theme.Space.s)

        if addonSync.needsFirstSyncChoice {
            SettingsRow(title: "Choose how to sync addons",
                        detail: "Your addons sync after you decide how to combine this device's addons with your account's.") {
                Button("Choose…") { choosingFirstSync = true }
                    .buttonStyle(.ds(.accent, compact: true))
            }
        }

        if let error = sync.lastError {
            StatusLine(kind: .error, text: error)
                .padding(.bottom, Theme.Space.s)
                .transition(.opacity)
        }

        HStack(spacing: Theme.Space.s) {
            Button {
                Task { await sync.syncNow() }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.ds(.secondary, compact: true))
            .disabled(sync.isSyncing || isSigningOut)
            Spacer(minLength: 0)
            Button("Sign Out…") { confirmingSignOut = true }
                .buttonStyle(.ds(.ghost, compact: true))
                .disabled(isSigningOut)
        }
    }
}

private struct SyncStatusText: View {
    @Environment(SyncCoordinator.self) private var sync

    var body: some View {
        Group {
            if sync.isSyncing {
                HStack(spacing: Theme.Space.xxs + 2) {
                    ProgressView().controlSize(.mini)
                    Text("Syncing…")
                }
            } else if let date = sync.lastSyncedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.lastSynced(date, now: context.date))
                }
            } else {
                Text("Not synced yet")
            }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Palette.textTertiary)
    }

    static func lastSynced(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Synced just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Last synced \(formatter.localizedString(for: date, relativeTo: now))"
    }
}

private struct AccountAvatar: View {
    var user: StremioUser
    private let size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(Theme.Palette.accentGradient)
            Text(initial)
                .font(.system(size: size * 0.42, weight: .heavy))
                .foregroundStyle(.white)
            if let url = user.avatar.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                RemoteImage(url: url, maxPixelSize: 128) { Color.clear }
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Theme.Palette.strokeStrong))
        .accessibilityHidden(true)
    }

    private var initial: String {
        let source = user.fullname?.isEmpty == false ? user.fullname! : user.email
        return source.first.map { String($0).uppercased() } ?? "?"
    }
}
