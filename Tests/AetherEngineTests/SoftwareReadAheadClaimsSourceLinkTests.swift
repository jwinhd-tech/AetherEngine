import Foundation
import Testing
@testable import AetherEngine

/// A software VOD session claims the source link while it reads, so a subtitle side reader yields to
/// it (#240). The link gate only heard from the native route's segment producer, so on a software
/// session (the Dolby Vision FEL route, DVDs, the software codecs) the side reader read beside the
/// playback reader for the whole session. On Matroska that reader is a second full copy of the stream.
///
/// The packet read-ahead's producer is the one place a software session pulls from its source, so the
/// claim follows its park: held while it reads, released before it waits and when it ends.
@Suite("Software read-ahead claims the source link while it reads", .offCooperativePool, .timeLimit(.minutes(3)))
struct SoftwareReadAheadClaimsSourceLinkTests {

    private static let tickRate: Int32 = 1000
    private static let holdTicks: Int64 = 40

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readahead-link-\(UUID().uuidString)", isDirectory: true)
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

    private static func readAhead(_ root: URL, gate: SideReaderLinkGate?,
                                  source: @escaping @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?
    ) throws -> SoftwarePacketReadAhead {
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        // Two seconds of forward window: the producer parks after 50 pictures.
        return SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: tickRate), audio: nil,
            byteBudget: 50_000_000, forwardSeconds: 2, initialSourceClock: 0, fifo: fifo,
            linkGate: gate, readSource: source)
    }

    @Test("#240: the producer holds the link inside a source read and releases it at the park and on close")
    func claimFollowsThePark() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SideReaderLinkGate()
        let reads = Counter()
        let firstReadMayFinish = DispatchSemaphore(value: 0)
        // The source runs on the producer's own thread, so the first read can block there while the
        // test looks at the gate: a producer inside the source is what a side reader must not race.
        let cache = try Self.readAhead(root, gate: gate) { _ in
            let index = reads.next()
            if index == 1 { firstReadMayFinish.wait() }
            return Self.packet(index)
        }
        #expect(gate.state.videoProducing == false, "nothing reads before the producer starts")

        cache.start()
        try await waitFor { reads.value >= 1 }
        #expect(gate.state.videoProducing, "a producer inside a source read holds the link")

        firstReadMayFinish.signal()
        try await waitFor { cache.producerParkedForTesting }
        #expect(gate.state.videoProducing == false,
                "a parked producer leaves the link to the side readers")

        cache.close()
        try await waitFor { !cache.producerParkedForTesting }
        #expect(gate.state.videoProducing == false, "closing leaves no claim behind")
    }

    @Test("#240: a read-ahead built without a gate reads and parks as before")
    func noGateIsNoChange() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = Counter()
        let cache = try Self.readAhead(root, gate: nil) { _ in Self.packet(reads.next()) }
        defer { cache.close() }
        cache.start()
        try await waitFor { cache.producerParkedForTesting }
        #expect(reads.value > 1)
    }
}
