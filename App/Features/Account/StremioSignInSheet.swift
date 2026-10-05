import SwiftUI

/// Sign-in flow for the optional Stremio account: optional intro (onboarding), email/password form, then the
/// first-sync addon choice when the account and this device both have addons. OWNER: Stremio Agent 5.
struct StremioSignInSheet: View {
    enum Step: Hashable { case intro, form, firstSync }

    @Environment(\.dismiss) private var dismiss
    @Environment(StremioAccount.self) private var account
    @Environment(AddonSync.self) private var addonSync
    @Environment(SyncCoordinator.self) private var sync
    @State private var step: Step

    init(startAt step: Step = .form) {
        _step = State(initialValue: step)
    }

    var body: some View {
        ScrollView {
            Group {
                switch step {
                case .intro:
                    AccountIntroView(onSignIn: { withAnimation(Theme.Motion.content) { step = .form } },
                                     onSkip: { dismiss() })
                case .form:
                    StremioSignInForm(onCancel: { dismiss() }, onSignedIn: signedIn)
                case .firstSync:
                    FirstSyncChoiceView(onDone: { dismiss() })
                }
            }
            .padding(.horizontal, SettingsMetrics.pageGutter)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .scrollBounceBehavior(.basedOnSize)
        .dsCanvas()
        #if os(macOS)
        .frame(width: 520)
        .frame(minHeight: 460)
        #endif
    }

    private func signedIn() {
        if addonSync.needsFirstSyncChoice {
            withAnimation(Theme.Motion.content) { step = .firstSync }
        } else {
            dismiss()
            Task { await sync.syncNow() }
        }
    }
}

/// Lightweight first-launch pitch; skippable.
private struct AccountIntroView: View {
    var onSignIn: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            BrandMark(height: 52)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Already use Stremio?")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Sign in to bring your addons, library and watch progress with you, and keep them in sync. You can always do this later in Settings.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                bullet("puzzlepiece.extension.fill", "Your addons, ready to browse")
                bullet("bookmark.fill", "Your library and watched episodes")
                bullet("play.circle.fill", "Continue watching where you left off")
            }
            VStack(spacing: Theme.Space.s) {
                Button("Sign In with Stremio", action: onSignIn)
                    .buttonStyle(.ds(.accent, fullWidth: true))
                    .keyboardShortcut(.defaultAction)
                Button("Continue Without Account", action: onSkip)
                    .buttonStyle(.ds(.ghost, fullWidth: true))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, Theme.Space.xs)
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Palette.accentHover)
                .frame(width: 28, height: 28)
                .background(Theme.Palette.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(text)
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
    }
}

private struct StremioSignInForm: View {
    var onCancel: () -> Void
    var onSignedIn: () -> Void

    @Environment(StremioAccount.self) private var account
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private static let registerURL = URL(string: "https://www.stremio.com/register")!

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Sign in to Stremio")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Sync your addons, library and watch progress with your Stremio account.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Theme.Space.s) {
                field(icon: "envelope.fill") {
                    TextField("Email", text: $email, prompt: prompt("Email"))
                        .textContentType(.username)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                }
                field(icon: "lock.fill") {
                    SecureField("Password", text: $password, prompt: prompt("Password"))
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                }
            }
            .disabled(isSigningIn)

            if let errorMessage {
                StatusLine(kind: .error, text: errorMessage)
                    .transition(.opacity)
            }

            HStack(spacing: Theme.Space.s) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.ds(.ghost))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button(action: signIn) {
                    HStack(spacing: Theme.Space.xs) {
                        if isSigningIn {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(isSigningIn ? "Signing In…" : "Sign In")
                    }
                }
                .buttonStyle(.ds(.accent))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }

            Link(destination: Self.registerURL) {
                Label("Create an account at stremio.com", systemImage: "arrow.up.forward.square")
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accentHover)
            }
            .buttonStyle(.plain)
        }
        .autocorrectionDisabled()
        .animation(Theme.Motion.appear, value: errorMessage)
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .onAppear { focus = .email }
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSubmit: Bool { !isSigningIn && !trimmedEmail.isEmpty && !password.isEmpty }

    private func signIn() {
        guard canSubmit else { return }
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await account.login(email: trimmedEmail, password: password)
                password = ""
                isSigningIn = false
                onSignedIn()
            } catch {
                isSigningIn = false
                errorMessage = Self.message(for: error)
                focus = .password
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? StremioAPIError {
            switch apiError {
            case .invalidCredentials: return "Wrong email or password."
            case .notImplemented: return "Signing in isn't available yet."
            case .server(let message) where !message.isEmpty: return "Stremio couldn't sign you in: \(message)"
            default: return apiError.errorDescription ?? "Signing in failed. Try again."
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Connect to the internet to sign in."
            default:
                return "Couldn't reach Stremio. Try again in a moment."
            }
        }
        if error is Keychain.Failure { return "Signed in, but the session couldn't be saved to the Keychain. Try again." }
        return "Signing in failed. Try again."
    }

    private func prompt(_ text: String) -> Text {
        Text(text).foregroundStyle(Theme.Palette.textTertiary)
    }

    private func field<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 18)
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.textPrimary)
                .labelsHidden()
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 50)
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.Palette.strokeStrong))
    }
}

/// How to combine this device's addons with the account's on the first sync.
struct FirstSyncChoiceView: View {
    var onDone: () -> Void

    @Environment(AddonSync.self) private var addonSync
    @Environment(SyncCoordinator.self) private var sync
    @State private var choice: AddonSync.FirstSyncChoice = .merge
    @State private var isWorking = false
    @State private var errorMessage: String?

    private struct Option: Identifiable {
        var id: AddonSync.FirstSyncChoice
        var title: String
        var detail: String
        var icon: String
    }

    private let options: [Option] = [
        Option(id: .merge, title: "Merge both",
               detail: "Keep the addons on this device and add the ones from your account. Your account gets the combined list.",
               icon: "arrow.triangle.merge"),
        Option(id: .useAccount, title: "Use addons from your Stremio account",
               detail: "Replace this device's addons with the ones in your account.",
               icon: "icloud.and.arrow.down.fill"),
        Option(id: .keepThisDevice, title: "Keep this device's addons",
               detail: "Upload this device's addons to your account, replacing the addons there.",
               icon: "icloud.and.arrow.up.fill"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Sync your addons")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Your Stremio account and this device both have addons. Choose how to combine them. Library and watch progress are merged automatically.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Theme.Space.s) {
                ForEach(options) { option in
                    optionRow(option)
                }
            }
            .disabled(isWorking)

            if let errorMessage {
                StatusLine(kind: .error, text: errorMessage)
                    .transition(.opacity)
            }

            HStack(spacing: Theme.Space.s) {
                // Addons don't sync until a choice is made; Settings keeps offering it.
                Button("Not Now", action: onDone)
                    .buttonStyle(.ds(.ghost))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Spacer()
                Button(action: apply) {
                    HStack(spacing: Theme.Space.xs) {
                        if isWorking { ProgressView().controlSize(.small).tint(.white) }
                        Text(isWorking ? "Syncing…" : "Continue")
                    }
                }
                .buttonStyle(.ds(.accent))
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
        }
        .animation(Theme.Motion.appear, value: errorMessage)
        .interactiveDismissDisabled(isWorking)
    }

    private func optionRow(_ option: Option) -> some View {
        let selected = option.id == choice
        return Button {
            withAnimation(Theme.Motion.fast) { choice = option.id }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: option.icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(selected ? .white : Theme.Palette.accentHover)
                    .frame(width: 32, height: 32)
                    .background(selected ? Theme.Palette.accent : Theme.Palette.accentSoft,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(option.detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
            }
            .padding(Theme.Space.m)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(selected ? Theme.Palette.accent : Theme.Palette.stroke, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func apply() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await addonSync.performFirstSync(choice)
                await sync.syncNow()
                isWorking = false
                onDone()
            } catch {
                isWorking = false
                errorMessage = SyncCoordinator.friendlyMessage(for: error)
            }
        }
    }
}
