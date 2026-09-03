import Foundation

/// The one place Usage makes a network call. Synchronous on purpose: every
/// caller is already on the model's work queue, and a blocking call with a
/// timeout is simpler to bound than a chain of callbacks.
public enum HTTP {

    public enum Failure: Error, Equatable, Sendable {
        /// 401 or 403: the credential was refused.
        case auth
        /// Any other non-2xx.
        case status(Int)
        /// No answer: DNS, TLS, timeout.
        case network(String)

        public var message: String {
            switch self {
            case .auth: return "credential rejected"
            case let .status(code): return "HTTP \(code)"
            case let .network(reason): return reason
            }
        }
    }

    public static func get(
        _ url: URL,
        headers: [String: String],
        timeout: TimeInterval = 10
    ) -> Result<Data, Failure> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let done = DispatchSemaphore(value: 0)
        var outcome: Result<Data, Failure> = .failure(.network("no response"))
        let task = session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                let urlError = error as? URLError
                outcome = .failure(.network(urlError?.code == .timedOut ? "timeout" : "network error"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(.network("no HTTP response"))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                outcome = .failure(.auth)
            } else if !(200..<300).contains(http.statusCode) {
                outcome = .failure(.status(http.statusCode))
            } else {
                outcome = .success(data ?? Data())
            }
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            return .failure(.network("timeout"))
        }
        return outcome
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "usage-bar/1.0 (house)"]
        return URLSession(configuration: configuration)
    }()
}
