import Foundation

/// Stateless HTTP client for the Stremio addon protocol. OWNER: Agent 1 (Core).
/// Never include addon URLs in errors: they may embed secrets. Use `Addon.redact`.
struct AddonClient: Sendable {
    var session: URLSession = .shared
    var timeout: TimeInterval = 10
    /// Stream addons (Comet) can be slow to answer while they search, so they get longer.
    var streamTimeout: TimeInterval = 15

    func fetchManifest(from manifestURL: String) async throws -> Manifest {
        let normalized = Addon.normalizeManifestURL(manifestURL)
        guard let url = URL(string: normalized), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { throw AddonError.invalidURL }
        let manifest: Manifest = try await get(url, label: Addon.redact(normalized), timeout: timeout)
        guard !manifest.id.isEmpty else {
            throw AddonError.decoding(addon: Addon.redact(normalized), underlying: "manifest has no id")
        }
        return manifest
    }

    func catalog(_ addon: Addon, type: String, id: String, search: String? = nil, skip: Int? = nil, genre: String? = nil) async throws -> [MetaPreview] {
        let declared = addon.manifest.catalogs.first { $0.type == type && $0.id == id }
        let extras = Self.catalogExtras(search: search, skip: skip, genre: genre, order: declared?.extraOrder ?? [])
        let url = try resourceURL(addon, "catalog", type: type, id: id, extras: extras)
        let response: CatalogResponse = try await get(url, label: addon.redactedURL, timeout: timeout)
        return response.metas
    }

    func meta(_ addon: Addon, type: String, id: String) async throws -> MetaDetail {
        let url = try resourceURL(addon, "meta", type: type, id: id)
        let response: OptionalMetaResponse = try await get(url, label: addon.redactedURL, timeout: timeout)
        guard let meta = response.meta else { throw AddonError.notFound }
        return meta
    }

    func streams(_ addon: Addon, type: String, id: String) async throws -> [Stream] {
        let url = try resourceURL(addon, "stream", type: type, id: id)
        let response: StreamResponse = try await get(url, label: addon.redactedURL, timeout: streamTimeout)
        return response.streams
    }

    // MARK: - URL building (pure, tested)

    /// Extras for a catalog request (nil/empty values omitted), in the catalog's declared `order`;
    /// undeclared extras follow in the default order search, genre, skip.
    static func catalogExtras(search: String?, skip: Int?, genre: String?, order: [String] = []) -> [(String, String)] {
        var extras: [(String, String)] = []
        if let search, !search.trimmingCharacters(in: .whitespaces).isEmpty { extras.append(("search", search)) }
        if let genre, !genre.isEmpty { extras.append(("genre", genre)) }
        if let skip, skip > 0 { extras.append(("skip", String(skip))) }
        let rank = { (name: String) in order.firstIndex(of: name) ?? order.count }
        return extras.enumerated()
            .sorted { (rank($0.element.0), $0.offset) < (rank($1.element.0), $1.offset) }
            .map(\.element)
    }

    /// `{base}/{resource}/{type}/{id}.json` or `{base}/{resource}/{type}/{id}/{extras}.json`.
    static func resourceURL(base: URL, resource: String, type: String, id: String, extras: [(String, String)] = []) -> URL? {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        s += "/\(resource)/\(encodePathSegment(type))/\(encodePathSegment(id))"
        if !extras.isEmpty {
            s += "/" + extras.map { "\(encodeExtra($0.0))=\(encodeExtra($0.1))" }.joined(separator: "&")
        }
        return URL(string: s + ".json")
    }

    /// Path segment encoding that keeps `:` (Stremio ids like `tt0903747:1:1`) but escapes `/`, `?`, `#`, `%`, spaces etc.
    static func encodePathSegment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? s
    }

    /// Like JS `encodeURIComponent`: escapes everything except `A-Za-z0-9-_.!~*'()`.
    static func encodeExtra(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: extraAllowed) ?? s
    }

    private static let pathSegmentAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:@!$'()*,;")
    private static let extraAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")

    // MARK: - Networking

    private func resourceURL(_ addon: Addon, _ resource: String, type: String, id: String, extras: [(String, String)] = []) throws -> URL {
        guard let base = addon.baseURL,
              let url = Self.resourceURL(base: base, resource: resource, type: type, id: id, extras: extras)
        else { throw AddonError.invalidURL }
        return url
    }

    private func get<T: Decodable>(_ url: URL, label: String, timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AddonError.network(addon: label, underlying: Self.describe(error))
        } catch {
            throw AddonError.network(addon: label, underlying: "request failed")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AddonError.http(status: http.statusCode, addon: label)
        }
        return try Self.decode(T.self, from: data, label: label)
    }

    /// Decodes an addon response, surfacing an addon-reported `{"err": ...}` when the body doesn't match.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, label: String) throws -> T {
        if let addonErr = try? JSONDecoder().decode(AddonErrorBody.self, from: data), let message = addonErr.message {
            throw AddonError.addon(addon: label, message: message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw AddonError.decoding(addon: label, underlying: describe(error))
        } catch {
            throw AddonError.decoding(addon: label, underlying: "invalid JSON")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let ctx): return "missing \"\(key.stringValue)\" at \(path(ctx).isEmpty ? "root" : path(ctx))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx): return "wrong type at \(path(ctx).isEmpty ? "root" : path(ctx))"
        case .dataCorrupted: return "not valid JSON"
        @unknown default: return "invalid response"
        }
    }

    /// URLError's own descriptions are fine, but its userInfo carries the failing URL; never forward the error itself.
    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "timed out"
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: "no internet connection"
        case .cannotFindHost, .dnsLookupFailed: "host not found"
        case .cannotConnectToHost: "connection refused"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: "secure connection failed"
        case .badServerResponse: "bad server response"
        case .httpTooManyRedirects, .redirectToNonExistentLocation: "redirect error"
        default: "network error \(error.code.rawValue)"
        }
    }
}

private struct OptionalMetaResponse: Decodable {
    var meta: MetaDetail?
}

/// Some addons answer `{"err": "..."}` (string or object) instead of the expected payload.
private struct AddonErrorBody: Decodable {
    var message: String?

    private enum CodingKeys: String, CodingKey { case err, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = c.decodeLossyString(forKey: .err) ?? c.decodeLossyString(forKey: .error)
        if let raw {
            message = String(raw.prefix(200))
        } else if c.contains(.err) || c.contains(.error), (try? c.decodeNil(forKey: .err)) != true {
            message = "unknown error"
        }
    }
}

enum AddonError: LocalizedError, Sendable {
    case notImplemented
    case invalidURL
    case http(status: Int, addon: String)
    case decoding(addon: String, underlying: String)
    case network(addon: String, underlying: String)
    case addon(addon: String, message: String)
    case duplicate(addon: String)
    case notFound
    case timedOut(addon: String)

    var errorDescription: String? {
        switch self {
        case .notImplemented: "Not implemented"
        case .invalidURL: "Invalid addon URL"
        case .http(let status, let addon): "\(addon) returned HTTP \(status)"
        case .decoding(let addon, let e): "\(addon) sent an unexpected response: \(e)"
        case .network(let addon, let e): "\(addon) could not be reached: \(e)"
        case .addon(let addon, let message): "\(addon) reported an error: \(message)"
        case .duplicate(let name): "\(name) is already installed"
        case .notFound: "Not found"
        case .timedOut(let addon): "\(addon) timed out"
        }
    }
}
