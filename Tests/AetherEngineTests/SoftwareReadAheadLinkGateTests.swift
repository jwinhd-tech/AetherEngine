import Foundation
import Testing
@testable import AetherEngine

/// #240 on the software route. The side-reader link gate only heard from the native route's segment
/// producer, so a subtitle side reader never yielded to a software VOD session (the Dolby Vision FEL
/// route, DVDs, the software codecs). On Matroska that reader is a second full copy of the stream, and
/// against an origin that serves two readers of one file at 9.5 MiB/s each it held a 100 Mbit/s FEL
/// remux under its media rate until the session rebuffered, about 30 s after every seek.
///
/// The packet read-ahead's producer is the one place a software session pulls from its source, so it
/// claims the link while it reads and releases it when it parks or ends.
@Suite("Software read-ahead claims the side-reader link while it reads (#240)", .offCooperativePool, .timeLimit(.minutes(1)))
struct SoftwareReadAheadLinkGateTests {

    private static let tickRate: Int32 = 1000
    private static let holdTicks: Int64 = 40

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkgate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// 25 video pictures a second, a keyframe every second.
    private static func packet(_ index: Int) -> SoftwareStoredPacket {
        let pts = Int64(index - 1) * holdTicks
        return SoftwareStoredPacket(pts: pts, dts: pts, duration: holdTicks, position: 0,
                                    streamIndex: 0, flags: (index - 1) % 25 == 0 ? 0x1 : 0,
                                    timeBaseNumerator: 1, timeBaseDenominator: tickRate,
                                    bytes: Data(repeating: 7, count: 100), sideData: [])
    }

    private static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    @Test("the producer holds the link inside a source read and releases it at the park and on close")
    func claimFollowsThePark() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SideReaderLinkGate()
        let reads = Counter()
        let firstReadMayFinish = DispatchSemaphore(value: 0)
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        let cache = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: Self.tickRate), audio: nil,
            byteBudget: 50_000_000, forwardSeconds: 2, initialSourceClock: 0,
            fifo: fifo, linkGate: gate
        ) { _ in
            let index = reads.next()
            // A slow first read: the producer sits inside the source, which is what a side reader
            // must not compete with.
            if index == 1 { firstReadMayFinish.wait() }
            return Self.packet(index)
        }
        #expect(gate.state.videoProducing == false, "nothing reads before the producer starts")

        cache.start()
        Self.waitUntil { reads.value >= 1 }
        #expect(gate.state.videoProducing, "a producer inside a source read holds the link")

        firstReadMayFinish.signal()
        Self.waitUntil { cache.producerParkedForTesting }
        #expect(cache.producerParkedForTesting, "two seconds of video fill the forward window")
        #expect(gate.state.videoProducing == false,
                "a parked producer leaves the link to the side readers")

        cache.close()
        Self.waitUntil { !cache.producerParkedForTesting }
        #expect(gate.state.videoProducing == false, "closing never leaves a claim behind")
    }

    @Test("a producer built without a gate reads as before")
    func noGateIsNoChange() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = Counter()
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        let cache = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: Self.tickRate), audio: nil,
            byteBudget: 50_000_000, forwardSeconds: 2, initialSourceClock: 0,
            fifo: fifo
        ) { _ in Self.packet(reads.next()) }
        cache.start()
        defer { cache.close() }
        Self.waitUntil { cache.producerParkedForTesting }
        #expect(cache.producerParkedForTesting)
        #expect(reads.value > 1)
    }
}
