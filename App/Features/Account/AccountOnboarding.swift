import SwiftUI

/// One-time, skippable "Sign in with Stremio / Continue without account" prompt. Never shown again once presented.
private struct AccountOnboarding: ViewModifier {
    @Environment(StremioAccount.self) private var account
    @AppStorage("onboarding.stremioAccountPromptSeen") private var seen = false
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !seen, !account.isSignedIn, !Self.isRunningTests else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, !seen, !account.isSignedIn else { return }
                seen = true
                presented = true
            }
            .sheet(isPresented: $presented) { StremioSignInSheet(startAt: .intro) }
    }

    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

extension View {
    func accountOnboarding() -> some View { modifier(AccountOnboarding()) }
}
