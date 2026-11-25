import Foundation

/// Where the app's work with the engine runs: off Swift's few worker threads, in a lane per photo.
/// A render waits for its photo (the engine draws a photo one thing at a time); on a worker thread
/// that wait would hold the thread, and once they are all held everything else the app does stalls
/// with them: the library's thumbnails, other photos' pictures, their conversations. Here it holds
/// a thread of its own. Work on one photo runs in order, and photos do not wait for each other.
/// Work whose caller has stopped waiting (a card scrolled away, a picture already replaced) is
/// dropped when its turn comes instead of being drawn for nobody.
enum Rendering {
    private static let lanes = Lanes()

    /// Runs `work` in its turn among the work on `photo` (any name that stands for one), and returns what it gives.
    static func run<T: Sendable>(for photo: String, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let dropped = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lanes.add(photo) {
                    if dropped.isSet {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(with: Result { try work() })
                    }
                }
            }
        } onCancel: {
            dropped.set()
        }
    }

    /// The same, for work whose failure is nothing: nil when it failed or was dropped.
    static func value<T: Sendable>(for photo: String, _ work: @escaping @Sendable () throws -> T?) async -> T? {
        (try? await run(for: photo, work)) ?? nil
    }

    /// Work that nothing waits for (closing a photo), in its turn.
    static func later(for photo: String, _ work: @escaping @Sendable () -> Void) {
        lanes.add(photo, work)
    }

    /// A serial queue for each photo with work waiting, kept while it has some.
    private final class Lanes: @unchecked Sendable {
        private let lock = NSLock()
        private var lanes: [String: (queue: DispatchQueue, waiting: Int)] = [:]
        private let threads = DispatchQueue(label: "oscuru.rendering", qos: .userInitiated, attributes: .concurrent)

        func add(_ photo: String, _ work: @escaping @Sendable () -> Void) {
            let queue = lock.withLock {
                var lane = lanes[photo] ?? (DispatchQueue(label: "oscuru.rendering.photo", target: threads), 0)
                lane.waiting += 1
                lanes[photo] = lane
                return lane.queue
            }
            queue.async {
                work()
                self.lock.withLock {
                    guard var lane = self.lanes[photo] else { return }
                    lane.waiting -= 1
                    self.lanes[photo] = lane.waiting > 0 ? lane : nil
                }
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
