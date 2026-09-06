import Foundation

/// The one place Usage makes a network call. Synchronous on purpose: every
/// caller is already on the model's work queue, and a blocking call with a
/// timeout is simpler to bound than a chain of callbacks.
public enum HTTP {

    public enum Failure: Error, Equatable, Sendable {
        /// 401 or 403: the credential was refused.
        case auth
        /// 429: the source throttled the ask, with the Retry-After seconds it
        /// sent, if any.
        case rateLimited(TimeInterval?)
        /// Any other non-2xx.
        case status(Int)
        /// No answer: DNS, TLS, timeout.
        case network(String)

        public var message: String {
            switch self {
            case .auth: return "credential rejected"
            case let .rateLimited(retryAfter):
                if let retryAfter { return "rate limited, retry in \(Int(retryAfter))s" }
                return "rate limited"
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
                // The system's own words for the failure ("The Internet
                // connection appears to be offline"), shortened to one line.
                let urlError = error as? URLError
                let words = urlError?.code == .timedOut ? "timeout" : error.localizedDescription
                outcome = .failure(.network(String(words.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(.network("no HTTP response"))
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                outcome = .failure(.auth)
            } else if http.statusCode == 429 {
                let retryAfter = Backoff.retryAfterSeconds(from: http.value(forHTTPHeaderField: "Retry-After"), now: Date())
                outcome = .failure(.rateLimited(retryAfter))
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
