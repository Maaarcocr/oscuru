import Foundation
import OscuruCore
import Synchronization

/// The app's HTTP transport. Requests to the model are given no deadline: a long think is allowed
/// to take as long as it takes, and only the person stopping it (or the connection dropping) ends it.
enum Network {
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60 * 60 * 24
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    static let session = URLSession(configuration: configuration)

    static func urlRequest(_ request: HTTPRequest) throws -> URLRequest {
        guard let url = URL(string: request.url) else { throw ModelError(.badRequest, "Bad address: \(request.url)") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = 60 * 60 * 24
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return urlRequest
    }

    static let transport: HTTPTransport = { request in
        do {
            let (data, response) = try await session.data(for: try urlRequest(request))
            return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    /// Streams the model's answer. Each request has a connection of its own (a session of its
    /// own), so a connection that died while the app was away is never handed to the next
    /// request; and the upload reports its progress, so a long one counts as the connection
    /// being alive.
    static let stream: HTTPStreamTransport = { request, progress in
        let urlRequest = try urlRequest(request)
        let session = URLSession(configuration: configuration)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: UploadProgress(progress))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let lines = AsyncThrowingStream<String, Error> { continuation in
                let reading = Task {
                    do {
                        for try await line in bytes.lines { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    reading.cancel()
                    session.invalidateAndCancel()
                }
            }
            return HTTPStreamResponse(status: status, lines: lines)
        } catch let error as URLError where error.code == .cancelled {
            session.invalidateAndCancel()
            throw CancellationError()
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    /// Waits `seconds` before a failed request is sent again, or less: until the app is back on
    /// screen or the network is back, whichever comes first.
    static func pause(_ seconds: Double) async throws {
        let id = UUID()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            group.addTask { await Wakeups.wait(id) }
            await group.next()
            group.cancelAll()
            await Wakeups.release(id)
        }
        try Task.checkCancellation()
    }

    private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
        let progress: @Sendable () -> Void

        init(_ progress: @escaping @Sendable () -> Void) {
            self.progress = progress
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            progress()
        }
    }
}

/// What happens to the phone's connection, for requests under way: when the network last changed
/// (a connection made before that may be dead without knowing it), and the waits to cut short
/// when the app is back on screen or the network is back.
enum Connection {
    private static let changed = Mutex<Date?>(nil)

    /// When the way the phone reaches the internet last changed (Wi-Fi to cellular, lost, back).
    static var lastChange: Date? { changed.withLock { $0 } }

    static func networkChanged(reachable: Bool) {
        changed.withLock { $0 = Date() }
        if reachable { Task { @MainActor in Wakeups.wake() } }
    }

    /// How a streamed request watches its connection.
    static var watch: StreamWatch { StreamWatch(lastDisruption: { Connection.lastChange }) }
}

/// Retries waiting to be sent again, woken early when there is reason to think they would get
/// through now.
@MainActor
enum Wakeups {
    private enum State {
        case waiting(CheckedContinuation<Void, Never>)
        case woken
        case released
    }

    private static var states: [UUID: State] = [:]

    /// Every wait ends now.
    static func wake() {
        for (id, state) in states {
            guard case .waiting(let continuation) = state else { continue }
            continuation.resume()
            states[id] = .woken
        }
    }

    static func wait(_ id: UUID) async {
        if case .released = states[id] {
            states[id] = nil
            return
        }
        await withCheckedContinuation { states[id] = .waiting($0) }
    }

    /// The wait `id` is no longer needed, whether or not it has started.
    static func release(_ id: UUID) {
        switch states[id] {
        case .waiting(let continuation):
            continuation.resume()
            states[id] = nil
        case .woken:
            states[id] = nil
        case .released, nil:
            states[id] = .released
        }
    }
}
