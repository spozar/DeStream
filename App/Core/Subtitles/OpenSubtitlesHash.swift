import Foundation

/// What subtitle addons use to find subtitles synced to this exact release.
struct VideoFingerprint: Hashable, Sendable {
    /// 16 lowercase hex digits (OpenSubtitles hash).
    var hash: String?
    var size: Int64?
    var filename: String?

    /// Stremio subtitle extras, in the order Stremio sends them.
    var extras: [(String, String)] {
        var out: [(String, String)] = []
        if let hash, let size {
            out.append(("videoHash", hash))
            out.append(("videoSize", String(size)))
        }
        if let filename, !filename.isEmpty { out.append(("filename", filename)) }
        return out
    }
}

/// The OpenSubtitles movie hash: file size plus the sum of the first and last 64 KiB read as little-endian UInt64s (wrapping).
enum OpenSubtitlesHash {
    static let chunkSize = 65_536

    static func hash(size: Int64, head: Data, tail: Data) -> String {
        var value = UInt64(truncatingIfNeeded: size)
        for chunk in [head, tail] {
            chunk.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    var word: UInt64 = 0
                    for b in 0..<min(8, raw.count - offset) {
                        word |= UInt64(raw[offset + b]) << (8 * UInt64(b))
                    }
                    value &+= word
                    offset += 8
                }
            }
        }
        return String(format: "%016llx", value)
    }

    /// Reads at most 128 KiB; nil when the file can't be read or is empty.
    static func hash(fileAt url: URL) -> (hash: String, size: Int64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        let size = Int64(end)
        let count = Int(min(UInt64(chunkSize), end))
        guard (try? handle.seek(toOffset: 0)) != nil, let head = try? handle.read(upToCount: count),
              (try? handle.seek(toOffset: end - UInt64(count))) != nil, let tail = try? handle.read(upToCount: count),
              head.count == count, tail.count == count else { return nil }
        return (hash(size: size, head: head, tail: tail), size)
    }

    /// Hashes a remote file with two HTTP Range requests. nil when the server doesn't honor ranges or is too slow.
    /// The URL may embed secrets: never log it.
    static func hash(remote url: URL, timeout: TimeInterval = 4, session: URLSession = .shared) async -> (hash: String, size: Int64)? {
        await withTaskGroup(of: (hash: String, size: Int64)?.self) { group in
            group.addTask {
                async let headPart = range(url, "bytes=0-\(chunkSize - 1)", timeout: timeout, session: session)
                async let tailPart = range(url, "bytes=-\(chunkSize)", timeout: timeout, session: session)
                guard let head = await headPart, let tail = await tailPart,
                      let size = head.total, size == tail.total, size > 0 else { return nil }
                let count = Int(min(Int64(chunkSize), size))
                guard head.data.count >= count, tail.data.count >= count else { return nil }
                return (hash(size: size, head: head.data.prefix(count), tail: tail.data.suffix(count)), size)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Reads at most one chunk, so a server that ignores `Range` never streams the whole file.
    private static func range(_ url: URL, _ value: String, timeout: TimeInterval, session: URLSession) async -> (data: Data, total: Int64?)? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(value, forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else { return nil }
        var data = Data()
        data.reserveCapacity(chunkSize)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= chunkSize { break }
            }
        } catch {
            return nil
        }
        return (data, totalSize(contentRange: http.value(forHTTPHeaderField: "Content-Range")))
    }

    /// "bytes 0-65535/1234567" → 1234567.
    static func totalSize(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
