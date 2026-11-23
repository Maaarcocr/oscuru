import Foundation
import OscuruCore

/// The app's HTTP transport. Requests to the model are given no deadline: a long think is allowed
/// to take as long as it takes, and only the person stopping it (or the connection dropping) ends it.
enum Network {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60 * 60 * 24
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static let transport: HTTPTransport = { request in
        guard let url = URL(string: request.url) else { throw ModelError(.badRequest, "Bad address: \(request.url)") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = 60 * 60 * 24
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return HTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}
