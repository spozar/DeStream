import SwiftUI

/// Installed addons (enable, reorder, delete), adding one by manifest URL, and one-tap recommended addons. OWNER: UI Agent 1.
struct AddonSettingsView: View {
    @Environment(AddonRegistry.self) private var registry
    @Environment(StremioAccount.self) private var account
    @Environment(AddonSync.self) private var addonSync
    @State private var newURL = ""
    @State private var revealURL = false
    @State private var isAdding = false
    @State private var addingRecommendedID: String?
    @State private var errorMessage: String?
    @State private var addedName: String?
    @State private var pendingDelete: Addon?

    @FocusState private var fieldFocused: Bool

    var body: some View {
        SettingsPage(title: "Addons", subtitle: subtitle) {
            if let storageError = registry.storageError {
                storageWarning(storageError)
            }
            if account.isSignedIn {
                syncNote
            }
            addCard

            if !registry.recommendedNotInstalled.isEmpty {
                recommendedSection
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        installedTitle
                        Spacer()
                        orderHint.multilineTextAlignment(.trailing)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        installedTitle
                        orderHint.fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, Theme.Space.s)

                if registry.addons.isEmpty {
                    DSEmptyState(systemImage: "puzzlepiece.extension",
                                 title: "No addons yet",
                                 message: "Paste a manifest URL above, or add a recommended addon to start browsing.")
                        .frame(height: 300)
                        .dsCard()
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                ForEach(Array(registry.addons.enumerated()), id: \.element.id) { index, addon in
                    AddonCard(
                        addon: addon,
                        index: index,
                        count: registry.addons.count,
                        onDelete: { pendingDelete = addon }
                    )
                    .contextMenu { contextMenu(for: addon) }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }
            }
        }
        .animation(SettingsMetrics.listSpring, value: registry.addons)
        .animation(Theme.Motion.appear, value: errorMessage)
        .animation(Theme.Motion.appear, value: addedName)
        .animation(Theme.Motion.fast, value: newURL.isEmpty)
        .animation(Theme.Motion.fast, value: isAdding)
        .animation(SettingsMetrics.listSpring, value: registry.recommendedNotInstalled)
        .sensoryFeedback(.success, trigger: addedName) { _, new in new != nil }
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .confirmationDialog(
            "Remove \(pendingDelete?.manifest.name ?? "addon")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let addon = pendingDelete { registry.remove(addon) }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map(removalMessage) ?? "")
        }
        .onChange(of: newURL) {
            errorMessage = nil
            if !newURL.isEmpty { addedName = nil }
        }
    }

    private func removalMessage(for addon: Addon) -> String {
        let readd = Self.isRecommended(addon)
            ? "You can add it again from Recommended."
            : "Its manifest URL is deleted from this device, so you'll need to paste it again to re-add it."
        guard account.isSignedIn else { return readd }
        let accountNote = AddonSync.descriptor(for: addon).flags.protected
            ? "It stays in your Stremio account."
            : "It's also removed from your Stremio account."
        return "\(readd) \(accountNote)"
    }

    static func isRecommended(_ addon: Addon) -> Bool {
        let url = Addon.normalizeManifestURL(addon.manifestURL)
        return AddonRegistry.recommended.contains { Addon.normalizeManifestURL($0.manifestURL) == url }
    }

    private func storageWarning(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            StatusLine(kind: .warning, text: "\(message) Changes made now won't be saved.")
            Button {
                registry.loadFromStore()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.ds(.secondary, compact: true))
        }
    }

    private var subtitle: String {
        let enabled = registry.addons.filter(\.enabled).count
        let total = registry.addons.count
        return total == 0 ? "Connect catalogs and stream sources" : "\(enabled) of \(total) enabled"
    }

    private var syncNote: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .bold))
                Text(addonSync.needsFirstSyncChoice
                     ? "Addons aren't syncing yet. Choose how to combine them with your Stremio account in Settings."
                     : "Addon changes sync to your Stremio account\(account.user.map { " (\($0.email))" } ?? "").")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(Theme.Palette.textSecondary)
            let accountOnly = addonSync.accountOnlyAddonNames
            if !accountOnly.isEmpty {
                Text("Also in your Stremio account, not used here: \(accountOnly.joined(separator: ", "))")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var installedTitle: some View {
        Text("Installed")
            .font(Theme.Font.rowTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
    }

    private var orderHint: some View {
        Text("Earlier addons are asked first for metadata and listed first in streams.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
    }

    private var installingFromField: Bool { isAdding && addingRecommendedID == nil }

    private var canAdd: Bool {
        !isAdding && !newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.Palette.accentGradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add an addon")
                        .font(Theme.Font.rowTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Paste a Stremio manifest URL")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }

            HStack(spacing: Theme.Space.s) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Group {
                    if revealURL {
                        TextField("Manifest URL", text: $newURL, prompt: Text("https://…/manifest.json").foregroundStyle(Theme.Palette.textTertiary))
                    } else {
                        SecureField("Manifest URL", text: $newURL, prompt: Text("https://…/manifest.json").foregroundStyle(Theme.Palette.textTertiary))
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.textPrimary)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .focused($fieldFocused)
                .onSubmit(add)
                .disabled(isAdding)
                .labelsHidden()

                if !newURL.isEmpty, !isAdding {
                    Button {
                        newURL = ""
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .frame(width: SettingsMetrics.smallButton, height: SettingsMetrics.smallButton)
                    }
                    .buttonStyle(SettingsPressStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    .help("Clear")
                    .accessibilityLabel("Clear URL")
                }

                // System paste button: replaces the field with the clipboard (no paste-permission prompt on iOS).
                PasteButton(payloadType: String.self) { strings in
                    guard let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty else { return }
                    Task { @MainActor in
                        newURL = pasted
                        errorMessage = nil
                    }
                }
                #if os(iOS)
                .labelStyle(.iconOnly)
                #else
                .labelStyle(.titleAndIcon)
                #endif
                .buttonBorderShape(.capsule)
                .tint(Theme.Palette.accent)
                .controlSize(.small)
                .disabled(isAdding)

                Button {
                    revealURL.toggle()
                } label: {
                    Image(systemName: revealURL ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: SettingsMetrics.smallGlyph + 1, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: SettingsMetrics.smallButton, height: SettingsMetrics.smallButton)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(SettingsPressStyle())
                .help(revealURL ? "Hide URL" : "Show URL")
                .accessibilityLabel(revealURL ? "Hide URL" : "Show URL")
            }
            .padding(.leading, Theme.Space.m)
            .padding(.trailing, Theme.Space.xs)
            .frame(minHeight: 52)
            .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(fieldFocused ? Theme.Palette.accent : Theme.Palette.strokeStrong, lineWidth: fieldFocused ? 1.5 : 1))
            .animation(Theme.Motion.fast, value: fieldFocused)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) {
                    actionButtons(fill: false)
                    Spacer(minLength: 0)
                }
                VStack(spacing: Theme.Space.xs) {
                    actionButtons(fill: true)
                }
            }

            if let errorMessage {
                StatusLine(kind: .error, text: errorMessage)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let addedName {
                StatusLine(kind: .success, text: "Added \(addedName)")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("For TorBox: configure Comet at comet.elfhosted.com, enable TorBox with your API key, then copy the manifest URL here. The URL contains your key, so it is stored only in the Keychain.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.Palette.accent.opacity(0.16), .clear],
                                             startPoint: .topLeading, endPoint: .center))
                )
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.Palette.stroke))
    }

    @ViewBuilder
    private func actionButtons(fill: Bool) -> some View {
        Button(action: add) {
            HStack(spacing: Theme.Space.xs) {
                if installingFromField {
                    ProgressView().controlSize(.small).tint(.white)
                        .transition(.opacity.combined(with: .scale(scale: 0.5)))
                } else {
                    Image(systemName: "plus.circle.fill")
                        .transition(.opacity.combined(with: .scale(scale: 0.5)))
                }
                Text(installingFromField ? "Installing…" : "Install Addon")
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(.ds(.accent, fullWidth: fill))
        .disabled(!canAdd)
        #if os(macOS)
        .keyboardShortcut(.defaultAction)
        #endif
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Recommended")
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Free catalogs for browsing and discovery. No account or key needed.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Theme.Space.s)

            VStack(spacing: 0) {
                ForEach(Array(registry.recommendedNotInstalled.enumerated()), id: \.element.id) { index, rec in
                    if index > 0 { Divider().overlay(Theme.Palette.stroke) }
                    recommendedRow(rec)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .dsCard(padding: 0)
        }
    }

    private func recommendedRow(_ rec: RecommendedAddon) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: rec.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.accentGradient)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(rec.summary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                add(rec.manifestURL, recommendedID: rec.id)
            } label: {
                if addingRecommendedID == rec.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Add", systemImage: "plus")
                }
            }
            .buttonStyle(.ds(.secondary, compact: true))
            .disabled(isAdding)
            .accessibilityLabel("Add \(rec.name)")
        }
        .padding(SettingsMetrics.cardPadding)
    }

    @ViewBuilder
    private func contextMenu(for addon: Addon) -> some View {
        Button(addon.enabled ? "Disable" : "Enable") { registry.setEnabled(addon, !addon.enabled) }
        if let i = registry.addons.firstIndex(of: addon) {
            Button("Move Up") { registry.move(fromOffsets: [i], toOffset: i - 1) }
                .disabled(i == 0)
            Button("Move Down") { registry.move(fromOffsets: [i], toOffset: i + 2) }
                .disabled(i == registry.addons.count - 1)
        }
        Divider()
        Button("Remove…", role: .destructive) { pendingDelete = addon }
    }

    private func add() { add(newURL) }

    private func add(_ raw: String, recommendedID: String? = nil) {
        errorMessage = nil
        addedName = nil
        guard let url = Self.validate(raw) else {
            errorMessage = "Enter a valid http(s):// or stremio:// manifest URL."
            return
        }
        isAdding = true
        addingRecommendedID = recommendedID
        Task {
            defer {
                isAdding = false
                addingRecommendedID = nil
            }
            do {
                let addon = try await registry.add(manifestURL: url)
                addedName = addon.manifest.name
                if raw == newURL { newURL = "" }
            } catch {
                errorMessage = Self.safeMessage(for: error, url: url)
            }
        }
    }

    /// Normalizes user input; returns nil when it can't be a manifest URL.
    static func validate(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        s = Addon.normalizeManifestURL(s)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        if !url.path.hasSuffix("manifest.json") {
            s = s.hasSuffix("/") ? s + "manifest.json" : s + "/manifest.json"
        }
        return s
    }

    /// Error text that never contains the secret URL.
    static func safeMessage(for error: Error, url: String) -> String {
        let message: String
        switch error as? AddonError {
        case .invalidURL:
            message = "Enter a valid http(s):// or stremio:// manifest URL."
        case .http(let status, _) where status == 404:
            message = "No addon manifest was found at this URL (HTTP 404). Check that you copied the whole link."
        case .http(let status, _) where status == 401 || status == 403:
            message = "The addon refused the request (HTTP \(status)). Its configuration or API key may be invalid."
        case .decoding:
            message = "This URL doesn't point to a Stremio addon manifest. Copy the manifest link (ending in /manifest.json) from the addon's install page."
        case .duplicate(let name):
            message = "\(name) is already installed with this configuration."
        default:
            message = error.localizedDescription
        }
        return message.replacingOccurrences(of: url, with: Addon.redact(url))
    }
}

private struct AddonCard: View {
    let addon: Addon
    let index: Int
    let count: Int
    let onDelete: () -> Void
    @Environment(AddonRegistry.self) private var registry
    @State private var hovering = false

    var body: some View {
        // Header row (logo, name, toggle) on top, details full-width below, so the card also fits a phone.
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                logo
                VStack(alignment: .leading, spacing: 4) {
                    Text(addon.manifest.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Badge(text: "v\(addon.manifest.version)", tint: Theme.Palette.textSecondary)
                        if !addon.enabled {
                            Badge(text: "DISABLED", tint: Theme.Palette.warning)
                        }
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: Theme.Space.s)
                DSToggle(label: "Enable \(addon.manifest.name)", isOn: Binding(
                    get: { addon.enabled },
                    set: { registry.setEnabled(addon, $0) }
                ))
            }
            if let description = addon.manifest.description, !description.isEmpty {
                Text(description)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 6) {
                ForEach(capabilities, id: \.text) { cap in
                    Badge(text: cap.text, systemImage: cap.icon, tint: cap.tint)
                }
                if !typesLabel.isEmpty {
                    Text(typesLabel)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .padding(.vertical, 2)
                }
            }
            HStack(spacing: Theme.Space.xs) {
                Text(addon.redactedURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.s)
                smallIcon("chevron.up", label: "Move up", enabled: index > 0) {
                    registry.move(fromOffsets: [index], toOffset: index - 1)
                }
                smallIcon("chevron.down", label: "Move down", enabled: index < count - 1) {
                    registry.move(fromOffsets: [index], toOffset: index + 2)
                }
                smallIcon("trash", label: "Remove \(addon.manifest.name)", enabled: true, destructive: true, action: onDelete)
            }
            .opacity(hovering ? 1 : 0.85)
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Theme.Palette.surfaceHigh : Theme.Palette.surface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
            .strokeBorder(addon.enabled ? Theme.Palette.stroke : Theme.Palette.stroke.opacity(0.5)))
        .saturation(addon.enabled ? 1 : 0.2)
        .opacity(addon.enabled ? 1 : 0.7)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .animation(Theme.Motion.appear, value: addon.enabled)
    }

    private func smallIcon(_ icon: String, label: String, enabled: Bool, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: SettingsMetrics.smallGlyph, weight: .bold))
                .foregroundStyle(destructive ? Theme.Palette.danger : Theme.Palette.textSecondary)
                .frame(width: SettingsMetrics.smallButton, height: SettingsMetrics.smallButton)
                .background((destructive ? Theme.Palette.danger : Color.white).opacity(destructive ? 0.14 : 0.08), in: Circle())
        }
        .buttonStyle(SettingsPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(label)
        .accessibilityLabel(label)
    }

    private var logo: some View {
        RemoteImage(url: addon.manifest.logo?.imageURL, maxPixelSize: 168, contentMode: .fit) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.accentGradient)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(6)
        .frame(width: 56, height: 56)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Palette.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private struct Capability { let text: String; let icon: String; let tint: Color }

    private var capabilities: [Capability] {
        let names = Set(addon.manifest.resources.map(\.name))
        var caps: [Capability] = []
        if !addon.manifest.catalogs.isEmpty || names.contains("catalog") {
            let n = addon.manifest.catalogs.count
            caps.append(Capability(text: n > 0 ? "CATALOGS · \(n)" : "CATALOGS", icon: "square.grid.2x2.fill", tint: Theme.Palette.accentHover))
        }
        if names.contains("meta") {
            caps.append(Capability(text: "META", icon: "info.circle.fill", tint: Color(red: 0.35, green: 0.70, blue: 1.0)))
        }
        if names.contains("stream") {
            caps.append(Capability(text: "STREAMS", icon: "play.circle.fill", tint: Theme.Palette.success))
        }
        if names.contains("subtitles") {
            caps.append(Capability(text: "SUBTITLES", icon: "captions.bubble.fill", tint: Theme.Palette.warning))
        }
        return caps
    }

    private var typesLabel: String {
        addon.manifest.types.map(DisplayFormat.typeLabel).joined(separator: " · ")
    }
}

