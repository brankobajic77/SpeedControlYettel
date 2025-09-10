import Foundation

final class APIClient {
    private let baseURL: URL
    private let authProvider: () -> String?
    private let session: URLSession

    init(baseURL: URL, authProvider: @escaping () -> String?) {
        self.baseURL = baseURL
        self.authProvider = authProvider
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: config)
    }

    private func makeRequest(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var url = baseURL
        url.append(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        if let tok = authProvider() { req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization") }
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }

    func getCameras() async throws -> [CameraDTO] {
        let req = makeRequest(path: "/v1/traffic/cameras")
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp)
        return try JSONDecoder().decode([CameraDTO].self, from: data)
    }

    func getSegments() async throws -> [SegmentDTO] {
        let req = makeRequest(path: "/v1/traffic/segments")
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp)
        return try JSONDecoder().decode([SegmentDTO].self, from: data)
    }

    func postAvgSpeed(_ payload: AvgSpeedReportDTO) async throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let body = try enc.encode(payload)
        var req = makeRequest(path: "/v1/traffic/avg-speed-report", method: "POST", body: body)
        req.httpBody = body
        let (_, resp) = try await session.data(for: req)
        try Self.validate(resp)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "APIClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
    }
}

