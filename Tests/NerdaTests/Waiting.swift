import Testing

/// Waits for `condition`, looking again every 20 ms for up to `timeout`:
/// a state that never comes fails the test where it was waited for, rather
/// than leaving the run hanging.
@MainActor
func waitFor(_ comment: Comment = "Timed out waiting", timeout: Duration = .seconds(6),
             sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, try await !condition() { try await Task.sleep(for: .milliseconds(20)) }
    try #require(try await condition(), comment, sourceLocation: sourceLocation)
}
