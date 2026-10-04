import Foundation

/// Contract for zero-API browser automation publishing.
/// Adheres to Dependency Inversion and Interface Segregation principles (SOLID).
protocol BrowserPublishingProtocol: Sendable {
    /// Inspects saved cookies in the local profile to determine connection status.
    func checkAuthStatus() async throws -> BrowserAuthStatus

    /// Launches an interactive visible Google Chrome session allowing the user to log in.
    func openLoginSession() async throws -> BrowserAuthStatus

    /// Publishes a clip via browser automation, streaming live events.
    func publish(job: BrowserUploadJob) -> AsyncThrowingStream<BrowserPublishEvent, Error>
}
