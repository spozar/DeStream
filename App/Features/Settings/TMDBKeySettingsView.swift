import SwiftUI

/// Connect / remove the optional TMDB key that powers "Because you watched" suggestions. OWNER: Rec Agent 4.
/// Pass `isPresentedAsSheet: true` when showing it in a sheet; it then adds its own Done button.
struct TMDBKeySettingsView: View {
    var isPresentedAsSheet = false
    @Environment(\.dismiss) private var dismiss

    init(isPresentedAsSheet: Bool = false) {
        self.isPresentedAsSheet = isPresentedAsSheet
    }

    var body: some View {
        if isPresentedAsSheet {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            Text("Better Suggestions")
                                .font(Theme.Font.title)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text("Connect TMDB for personal picks")
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer(minLength: Theme.Space.m)
                        Button("Done") { dismiss() }
                            .buttonStyle(.ds(.secondary, compact: true))
                            .keyboardShortcut(.cancelAction)
                    }
                    TMDBKeyCard()
                }
                .padding(.horizontal, SettingsMetrics.pageGutter)
                .padding(.vertical, Theme.Space.xl)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .dsCanvas()
            #if os(macOS)
            .frame(width: 560)
            .frame(minHeight: 440)
            #endif
        } else {
            SettingsPage(title: "Suggestions", subtitle: "Personal picks based on what you watch") {
                TMDBKeyCard()
            }
        }
    }
}

/// Settings entry: TMDB connection status (opening `TMDBKeySettingsView` in a sheet) and resetting "Not interested".
struct SuggestionsSettingsSection: View {
    @Environment(TMDBKeyStore.self) private var store
    @Environment(Recommendations.self) private var recommendations
    @State private var editing = false

    var body: some View {
        let hidden = recommendations.dismissedIDs.count
        SettingsCard(title: "Suggestions", systemImage: "sparkles") {
            SettingsRow(title: store.hasKey ? "TMDB connected" : "TMDB not connected",
                        detail: store.hasKey
                            ? "For You uses TMDB for \"Because you watched\" picks."
                            : "Optional. Add a free TMDB key for better \"Because you watched\" picks.",
                        divider: false) {
                Button(store.hasKey ? "Manage…" : "Connect…") { editing = true }
                    .buttonStyle(.ds(store.hasKey ? .secondary : .accent, compact: true))
            }
            SettingsRow(title: "Watch history",
                        detail: ignoredDetail(recommendations.ignoredSeedIDs.count)) {
                NavigationLink("View…", value: Route.watchHistory)
                    .buttonStyle(.ds(.secondary, compact: true))
            }
            if hidden > 0 {
                SettingsRow(title: "Hidden titles",
                            detail: "\(hidden) \(hidden == 1 ? "title" : "titles") marked \"Not Interested\" won't be suggested.") {
                    Button("Reset") {
                        withAnimation(Theme.Motion.content) { recommendations.resetDismissed() }
                        Task { await recommendations.load(force: true) }
                    }
                    .buttonStyle(.ds(.secondary, compact: true))
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $editing) { TMDBKeySettingsView(isPresentedAsSheet: true) }
    }

    private func ignoredDetail(_ count: Int) -> String {
        count == 0 ? "Choose which watched titles your suggestions are based on."
            : "\(count) watched \(count == 1 ? "title doesn't" : "titles don't") count toward suggestions."
    }
}

private struct TMDBKeyCard: View {
    @Environment(TMDBKeyStore.self) private var store
    @State private var key = ""
    @State private var reveal = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmingRemove = false
    @FocusState private var fieldFocused: Bool

    private static let apiSettingsURL = URL(string: "https://www.themoviedb.org/settings/api")!

    var body: some View {
        SettingsCard(title: "TMDB", systemImage: "film.stack.fill",
                     footer: "This product uses the TMDB API but is not endorsed or certified by TMDB.") {
            if store.hasKey {
                connected
            } else {
                connectForm
            }
        }
        .animation(Theme.Motion.content, value: store.hasKey)
        .animation(Theme.Motion.appear, value: errorMessage)
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .confirmationDialog("Remove TMDB key?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { store.remove() }
        } message: {
            Text("Suggestions will fall back to Cinemeta. You can add a key again at any time.")
        }
    }

    private var connected: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connected")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("For You uses TMDB for \"Because you watched\" picks. Your key is stored only in the Keychain.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            Button("Remove…") { confirmingRemove = true }
                .buttonStyle(.ds(.ghost, compact: true))
        }
        .padding(.vertical, SettingsMetrics.rowPadding)
        .transition(.opacity)
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("A free TMDB key gives you better \"Because you watched\" suggestions. Without one, DeStream falls back to Cinemeta.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: Self.apiSettingsURL) {
                Label("Get a free key at themoviedb.org", systemImage: "arrow.up.forward.square")
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accentHover)
            }
            .buttonStyle(.plain)

            keyField

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) {
                    saveButton(fill: false)
                    Spacer(minLength: 0)
                }
                saveButton(fill: true)
            }

            if let errorMessage {
                StatusLine(kind: .error, text: errorMessage)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("Paste either the API key (v3) or the API read access token (v4).")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }

    private var keyField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "key.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 18)
            Group {
                if reveal {
                    TextField("TMDB key", text: $key, prompt: prompt)
                } else {
                    SecureField("TMDB key", text: $key, prompt: prompt)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.Palette.textPrimary)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .focused($fieldFocused)
            .submitLabel(.done)
            .onSubmit(save)
            .disabled(isSaving)
            .labelsHidden()
            .onChange(of: key) { errorMessage = nil }

            Button {
                reveal.toggle()
            } label: {
                Image(systemName: reveal ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: SettingsMetrics.smallGlyph + 1, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: SettingsMetrics.smallButton, height: SettingsMetrics.smallButton)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(SettingsPressStyle())
            .help(reveal ? "Hide key" : "Show key")
            .accessibilityLabel(reveal ? "Hide key" : "Show key")
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.xs)
        .frame(minHeight: 50)
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            .strokeBorder(fieldFocused ? Theme.Palette.accent : Theme.Palette.strokeStrong, lineWidth: fieldFocused ? 1.5 : 1))
        .animation(Theme.Motion.fast, value: fieldFocused)
    }

    private var prompt: Text {
        Text("API key or read access token").foregroundStyle(Theme.Palette.textTertiary)
    }

    private func saveButton(fill: Bool) -> some View {
        Button(action: save) {
            HStack(spacing: Theme.Space.xs) {
                if isSaving {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(isSaving ? "Checking…" : "Save Key")
            }
        }
        .buttonStyle(.ds(.accent, fullWidth: fill))
        .disabled(!canSave)
        #if os(macOS)
        .keyboardShortcut(.defaultAction)
        #endif
    }

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool { !isSaving && !trimmedKey.isEmpty }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await store.save(trimmedKey)
                key = ""
                reveal = false
            } catch {
                errorMessage = Self.message(for: error)
                fieldFocused = true
            }
            isSaving = false
        }
    }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Connect to the internet to verify the key."
            default:
                return "Couldn't reach TMDB. Try again in a moment."
            }
        }
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return "TMDB didn't accept this key. Check it and try again."
    }
}
