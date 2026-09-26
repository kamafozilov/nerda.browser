import Testing
@testable import Nerda

/// A download's thousands of progress reports reach the main thread only as
/// often as its bar moves: every half percent, and at the end.
@Test func downloadProgressMovesEveryHalfPercent() {
    func reports(total: Int64, size: Int64) -> [Int64] {
        var drawn: (received: Int64, total: Int64) = (0, -1)
        var sent: [Int64] = []
        for received in stride(from: Int64(64 * 1024), through: size, by: 64 * 1024)
        where Download.moves(received: received, total: total, from: drawn) {
            drawn = (received, total)
            sent.append(received)
        }
        return sent
    }
    let size: Int64 = 1_024 * 1_024 * 1_024
    let known = reports(total: size, size: size)
    #expect((16_384, 201) == (size / (64 * 1024), known.count))
    #expect(known.last == size)
    // Size unknown: every 256 KB.
    #expect(reports(total: -1, size: size).count == 4_096)
}
