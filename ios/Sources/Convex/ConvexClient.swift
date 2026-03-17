import Foundation
import Combine
import ConvexMobile

// Convex client singleton for the app
// Docs: https://docs.convex.dev/client/swift
// API: subscribe(to:with:), mutation(_:with:), action(_:with:)

@MainActor
class ConvexClientManager: ObservableObject {
    static let shared = ConvexClientManager()

    let client: ConvexClientWithAuth<StackAuthResult>
    private var cancellables = Set<AnyCancellable>()

    @Published var isAuthenticated = false

    private init() {
        let env = Environment.current
        let provider = StackAuthProvider()
        client = ConvexClientWithAuth(deploymentUrl: env.convexURL, authProvider: provider)
        print("📦 Convex initialized (\(env.name)): \(env.convexURL)")

        // Observe auth state changes
        print("📦 Convex: Setting up authState subscription...")
        client.authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                print("📦 Convex: authState changed to: \(state)")
                switch state {
                case .authenticated(let authResult):
                    self?.isAuthenticated = true
                    print("📦 Convex: ✅ Authenticated (user: \(authResult.user.primaryEmail ?? "?"))")
                case .unauthenticated:
                    self?.isAuthenticated = false
                    print("📦 Convex: ❌ Unauthenticated")
                case .loading:
                    print("📦 Convex: ⏳ Auth loading...")
                }
            }
            .store(in: &cancellables)
        print("📦 Convex: authState subscription active, cancellables count: \(cancellables.count)")
    }

    /// Sync auth state with Stack Auth after user logs in via AuthManager
    /// Returns a description of what happened for debugging
    @discardableResult
    func syncAuth() async -> String {
        print("📦 Convex: Starting auth sync...")
        let result = await client.loginFromCache()
        switch result {
        case .success(let authResult):
            print("📦 Convex: Auth sync SUCCESS for \(authResult.user.primaryEmail ?? "unknown")")
            print("📦 Convex: Token was passed to ffiClient.setAuth()")
            let didAuthenticate = await waitUntilAuthenticated(timeout: .seconds(5))
            print("📦 Convex: isAuthenticated = \(didAuthenticate)")
            return "SUCCESS: \(authResult.user.primaryEmail ?? "unknown"), isAuth=\(didAuthenticate)"
        case .failure(let error):
            print("📦 Convex: Auth sync FAILED - \(error)")
            return "FAILED: \(error)"
        }
    }

    func waitUntilAuthenticated(timeout: Duration = .seconds(30)) async -> Bool {
        if isAuthenticated {
            return true
        }

        let waitState = ConvexAuthWaitState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let finish: @MainActor (Bool) -> Void = { value in
                    guard !waitState.didResume else { return }
                    waitState.didResume = true
                    waitState.cancellable?.cancel()
                    waitState.timeoutTask?.cancel()
                    continuation.resume(returning: value)
                }

                waitState.cancellable = client.authState
                    .receive(on: DispatchQueue.main)
                    .sink { state in
                        if case .authenticated = state {
                            finish(true)
                        }
                    }

                waitState.timeoutTask = Task {
                    try? await ContinuousClock().sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        finish(self.isAuthenticated)
                    }
                }
            }
        } onCancel: {
            waitState.cancellable?.cancel()
            waitState.timeoutTask?.cancel()
        }
    }

    /// Clear Convex auth state when user logs out
    func clearAuth() async {
        await client.logout()
    }
}

private final class ConvexAuthWaitState {
    var cancellable: AnyCancellable?
    var timeoutTask: Task<Void, Never>?
    var didResume = false
}
