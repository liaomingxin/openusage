import Foundation

enum MuseUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case paymentRequired

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Usage request failed. Check your connection."
        case .invalidResponse:
            return "Unexpected Muse Code usage response."
        case .requestFailed(let status):
            return "Usage request failed (HTTP \(status)). Try again later."
        case .paymentRequired:
            return "Muse Code requires an active subscription or payment method."
        }
    }
}

struct MuseUsageClient: Sendable {
    static let keyPath = "/muse-code/key"
    static let apiVersion = "1.0.0"

    private let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(credentials: MuseCredentials) async throws -> HTTPResponse {
        let base = MuseAuthStore.normalizeBaseURL(credentials.apiBaseURL)
        guard let url = URL(string: "\(base)\(Self.keyPath)") else {
            throw MuseUsageError.invalidResponse
        }
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Authorization": "Bearer \(credentials.accessToken)",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "x-api-version": Self.apiVersion
            ],
            body: Data("{}".utf8),
            timeout: 15
        )
        do {
            return try await http.send(request)
        } catch {
            throw MuseUsageError.connectionFailed
        }
    }
}
