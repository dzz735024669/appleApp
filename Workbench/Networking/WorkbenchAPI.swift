import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct Credentials: Codable {
    let username: String
    let password: String
}

enum APIError: LocalizedError {
    case invalidURL, malformedResponse, emptyFile, fileTooLarge
    case rejected(Int, String?)
    case recognitionConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无法构造工作台地址。"
        case .malformedResponse: return "服务器返回了无法识别的数据。"
        case .emptyFile: return "请选择有内容的文件。"
        case .fileTooLarge: return "单个附件不能超过 20 MB。"
        case .recognitionConflict(let message): return message
        case .rejected(let code, let message):
            switch code {
            case 401: return "用户名或密码不正确，请重新登录。"
            case 404: return "这条内容已不存在。"
            case 409: return "数据有冲突，可能已在另一台设备上更新。请刷新后重试。"
            case 413: return "上传内容超过服务器限制。"
            case 429: return "请求过于频繁，请稍后再试。"
            default: return message ?? "请求失败（\(code)），请稍后重试。"
            }
        }
    }

    var unauthorized: Bool {
        if case .rejected(401, _) = self { return true }
        return false
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct WorkbenchAPI {
    static let serverHostDisplay = "mynasdzz.mcdkf.top:7736"
    static let endpoint = URL(string: "https://\(serverHostDisplay)/api/v1")!
    static let attachmentLimit = 20 * 1024 * 1024

    private static let isoLock = NSLock()
    private static let isoWithFractional: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()
    private static let isoStandard: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format
    }()

    private static func parseISO8601(_ value: String) -> Date? {
        isoLock.lock()
        defer { isoLock.unlock() }
        return isoWithFractional.date(from: value) ?? isoStandard.date(from: value)
    }

    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    let credentials: Credentials

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { input in
            let value = try input.singleValueContainer().decode(String.self)
            guard let date = Self.parseISO8601(value) else { throw APIError.malformedResponse }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func request(_ path: [String], method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        var url = Self.endpoint
        for component in path { url.appendPathComponent(component) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIError.invalidURL }
        components.queryItems = query.isEmpty ? nil : query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let finalURL = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        let passwordPair = "\(credentials.username):\(credentials.password)"
        request.setValue("Basic \(Data(passwordPair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await Self.transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.malformedResponse }
        guard (200..<300).contains(response.statusCode) else {
            let problem = try? JSONDecoder().decode(Problem.self, from: data)
            throw APIError.rejected(response.statusCode, problem?.detail)
        }
        return data
    }

    private func fetch<T: Decodable>(_ request: URLRequest, as _: T.Type = T.self) async throws -> T {
        let data = try await perform(request)
        do { return try Self.decoder().decode(T.self, from: data) }
        catch { throw APIError.malformedResponse }
    }

    private func json<T: Encodable>(_ path: [String], method: String,
                                    query: [URLQueryItem] = [], body: T) throws -> URLRequest {
        var output = try request(path, method: method, query: query)
        output.setValue("application/json", forHTTPHeaderField: "Content-Type")
        output.httpBody = try Self.encoder().encode(body)
        return output
    }

    func signIn() async throws -> String {
        let session: Profile = try await fetch(request(["session"], method: "POST"))
        return session.username
    }

    func home(category: Category?) async throws -> HomeData {
        try await fetch(request(["home"], query: category.map { [.init(name: "category", value: $0.rawValue)] } ?? []))
    }

    func parseClipboard(_ text: String, requestID: UUID) async throws -> ClipboardParse {
        var output = try json(["ai", "clipboard", "parse"], method: "POST",
                              body: ClipboardInput(text: text, requestID: requestID))
        output.timeoutInterval = 40
        do {
            return try await fetch(output)
        } catch APIError.rejected(409, let detail) {
            throw APIError.recognitionConflict(detail ?? "这段内容仍在识别中，请稍后重试。")
        }
    }

    func items(kind: ItemKind? = nil, category: Category? = nil, status: ItemStatus? = nil, keyword: String? = nil,
               projectID: UUID? = nil, sourceID: UUID? = nil, year: String? = nil, offset: Int = 0) async throws -> ItemPage {
        let filters: [(String, String?)] = [
            ("kind", kind?.rawValue), ("category", category?.rawValue), ("status", status?.rawValue), ("q", keyword),
            ("project_id", projectID?.urlKey), ("source_id", sourceID?.urlKey), ("year", year), ("offset", String(offset))
        ]
        let query = filters.compactMap { filter -> URLQueryItem? in
            guard let value = filter.1 else { return nil }
            return .init(name: filter.0, value: value)
        }
        return try await fetch(request(["items"], query: query))
    }

    func item(_ id: UUID) async throws -> Item {
        try await fetch(request(["items", id.urlKey]))
    }

    func create(_ fields: ItemFields, key: UUID) async throws -> Item {
        var request = try json(["items"], method: "POST", body: fields)
        request.setValue(key.urlKey, forHTTPHeaderField: "Idempotency-Key")
        return try await fetch(request)
    }

    func update(_ item: Item, with fields: ItemFields) async throws -> Item {
        try await fetch(json(["items", item.id.urlKey], method: "PUT",
                             query: [.init(name: "revision", value: String(item.revision))], body: fields))
    }

    func delete(_ item: Item) async throws {
        _ = try await perform(request(["items", item.id.urlKey], method: "DELETE",
                                      query: [.init(name: "revision", value: String(item.revision))]))
    }

    func attachments(for id: UUID) async throws -> [Attachment] {
        let response: Attachments = try await fetch(request(["items", id.urlKey, "attachments"]))
        return response.attachments
    }

    func upload(_ data: Data, filename: String, to id: UUID) async throws -> Attachment {
        guard !data.isEmpty else { throw APIError.emptyFile }
        guard data.count <= Self.attachmentLimit else { throw APIError.fileTooLarge }
        var request = try request(["items", id.urlKey, "attachments"], method: "POST",
                                  query: [.init(name: "filename", value: filename)])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try await fetch(request)
    }

    func download(_ file: Attachment, from id: UUID) async throws -> Data {
        var request = try request(["items", id.urlKey, "attachments", file.id.urlKey])
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    func deleteAttachment(_ file: Attachment, from id: UUID) async throws {
        _ = try await perform(request(["items", id.urlKey, "attachments", file.id.urlKey], method: "DELETE"))
    }

    func shifts(start: String, end: String) async throws -> [Item] {
        let response: Shifts = try await fetch(request(["duty"], query: [.init(name: "start", value: start), .init(name: "end", value: end)]))
        return response.shifts
    }

    func preview(_ rule: DutyRule) async throws -> DutyPreview {
        try await fetch(json(["duty", "preview"], method: "POST", body: rule))
    }

    func save(_ rule: DutyRule) async throws {
        _ = try await perform(json(["duty", "schedule"], method: "POST", body: rule))
    }

    func addShifts(_ dates: [String]) async throws {
        _ = try await perform(json(["duty", "batch"], method: "POST", body: Dates(dates: dates)))
    }

    func registerDevice(_ id: UUID, token: String, environment: String) async throws {
        _ = try await perform(json(["devices", id.urlKey], method: "PUT", body: Device(token: token, environment: environment)))
    }

    func unregisterDevice(_ id: UUID) async throws {
        _ = try await perform(request(["devices", id.urlKey], method: "DELETE"))
    }

    private struct Profile: Decodable { let username: String }
    private struct ClipboardInput: Encodable {
        let text: String
        let requestID: UUID
        enum CodingKeys: String, CodingKey { case text; case requestID = "request_id" }
    }
    private struct Attachments: Decodable { let attachments: [Attachment] }
    private struct Shifts: Decodable { let shifts: [Item] }
    private struct Dates: Encodable { let dates: [String] }
    private struct Device: Encodable { let token: String; let environment: String }
    private struct Problem: Decodable {
        let detail: String?
        enum CodingKeys: String, CodingKey { case detail }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            detail = (try? fields.decode(String.self, forKey: .detail))
                ?? (try? fields.decode([Field].self, forKey: .detail))?.first.map { "\($0.field) · \($0.message)" }
        }
        private struct Field: Decodable { let field: String; let message: String }
    }
}

private extension UUID {
    var urlKey: String { uuidString.lowercased() }
}
