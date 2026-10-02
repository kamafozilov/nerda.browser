import Testing
@testable import Nerda

/// A page's own print, cancelled again and again, waits longer each time
/// after the third, as Chrome's does, and never more than 32 seconds.
@Test @MainActor func printingAgainWaitsLongerAfterEachCancel() {
    #expect((1...8).map { Printing.patience(afterCancelling: $0) } == [2, 2, 2, 4, 8, 16, 32, 32])
}
