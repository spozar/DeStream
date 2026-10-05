import Foundation
import os

struct DownloadResponseInfo: Sendable, Equatable {
    var statusCode: Int?
    var mimeType: String?
    var expectedLength: Int64
    var suggestedFilename: String?

    init(statusCode: Int? = nil, mimeType: String? = nil, expectedLength: Int64 = -1, suggestedFilename: String? = nil) {
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.expectedLength = expectedLength
        self.suggestedFilename = suggestedFilename
    }

    init?(_ response: URLResponse?) {
        guard let response else { return nil }
        statusCode = (response as? HTTPURLResponse)?.statusCode
        mimeType = response.mimeType
        expectedLength = response.expectedContentLength
        suggestedFilename = response.suggestedFilename
    }
}

struct DownloadErrorInfo: Sendable {
    var message: String
    var resumeData: Data?
    var isCancelled: Bool
    var isConnectivity: Bool
    var isOutOfSpace: Bool

    init(_ error: Error) {
        let ns = error as NSError
        message = ns.localizedDescription
        resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let urlError = ns.domain == NSURLErrorDomain
        isCancelled = urlError && ns.code == NSURLErrorCancelled
        isConnectivity = urlError && [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost,
            NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed,
        ].contains(ns.code)
        isOutOfSpace = DownloadErrorClassifier.isOutOfSpace(error)
    }
}

/// Events are keyed by `taskDescription` (the DownloadItem id) plus the task identifier to drop stale events.
enum DownloadEvent: Sendable {
    case progress(id: String, task: Int, written: Int64, expected: Int64, response: DownloadResponseInfo?)
    case waiting(id: String, task: Int)
    case finished(id: String, task: Int, file: URL, response: DownloadResponseInfo?)
    case stagingFailed(id: String, task: Int, message: String, isOutOfSpace: Bool)
    case completed(id: String, task: Int, error: DownloadErrorInfo?)
    case backgroundEventsFinished
}

/// Non-isolated URLSession delegate. Forwards everything to the DownloadManager through `sink`,
/// except moving the finished temp file, which must happen before `didFinishDownloadingTo` returns.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let stagingDirectory: URL
    private let sink: @Sendable (DownloadEvent) -> Void
    private let lastProgress = OSAllocatedUnfairLock<[Int: TimeInterval]>(initialState: [:])
    private static let progressInterval: TimeInterval = 0.5

    init(stagingDirectory: URL, sink: @escaping @Sendable (DownloadEvent) -> Void) {
        self.stagingDirectory = stagingDirectory
        self.sink = sink
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let taskID = downloadTask.taskIdentifier
        let now = ProcessInfo.processInfo.systemUptime
        let shouldSend = lastProgress.withLock { last -> Bool in
            if let t = last[taskID], now - t < Self.progressInterval { return false }
            last[taskID] = now
            return true
        }
        guard shouldSend else { return }
        sink(.progress(id: id, task: taskID, written: totalBytesWritten, expected: totalBytesExpectedToWrite,
                       response: DownloadResponseInfo(downloadTask.response)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let taskID = downloadTask.taskIdentifier
        let fm = FileManager.default
        let dest = stagingDirectory.appendingPathComponent("\(id)-\(taskID).download")
        do {
            try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            sink(.finished(id: id, task: taskID, file: dest, response: DownloadResponseInfo(downloadTask.response)))
        } catch {
            try? fm.removeItem(at: dest)
            sink(.stagingFailed(id: id, task: taskID, message: error.localizedDescription,
                                isOutOfSpace: DownloadErrorClassifier.isOutOfSpace(error)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier
        lastProgress.withLock { _ = $0.removeValue(forKey: taskID) }
        guard let id = task.taskDescription else { return }
        sink(.completed(id: id, task: taskID, error: error.map(DownloadErrorInfo.init)))
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let id = task.taskDescription else { return }
        sink(.waiting(id: id, task: task.taskIdentifier))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        sink(.backgroundEventsFinished)
    }
}
