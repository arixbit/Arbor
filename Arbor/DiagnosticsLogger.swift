import Foundation
import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers


/// 结构化、白名单字段的本地诊断日志。
///
/// 记录仓库 basename 而不是完整路径；调用方只传 operation/code，不传错误正文、
/// remote URL、提交消息或文件内容。日志按 5 MiB 滚动，保留当前文件和两个旧文件。
final class DiagnosticsLogger: @unchecked Sendable {
    static let shared = DiagnosticsLogger()

    private struct Record: Encodable {
        let timestamp: String
        let level: String
        let version: String
        let operation: String
        let repository: String?
        let code: String
    }

    private let queue = DispatchQueue(label: "com.arbor.diagnostics", qos: .utility)
    private let osLogger = Logger(subsystem: "com.arbor.app", category: "diagnostics")
    private let encoder = JSONEncoder()
    private let dateFormatter: ISO8601DateFormatter
    private let fileManager = FileManager.default
    private let maxBytes = 5 * 1024 * 1024
    private let retainedFiles = 3

    private var logDirectory: URL {
        fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Arbor", isDirectory: true)
    }

    private var logURL: URL { logDirectory.appendingPathComponent("arbor.log") }

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dateFormatter = formatter
    }

    func record(
        level: OSLogType = .info,
        operation: String,
        repositoryPath: String? = nil,
        code: String
    ) {
        queue.async { [self] in
            do {
                try append(
                    Record(
                        timestamp: dateFormatter.string(from: Date()),
                        level: level == .error ? "error" : "info",
                        version: appVersion,
                        operation: operation,
                        repository: repositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                        code: code
                    )
                )
                if level == .error {
                    osLogger.error("operation=\(operation, privacy: .public) code=\(code, privacy: .public)")
                } else {
                    osLogger.info("operation=\(operation, privacy: .public) code=\(code, privacy: .public)")
                }
            } catch {
                osLogger.error("diagnostic log write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 将当前及滚动日志打包到用户明确选择的路径；不上传、不打开网络连接。
    func exportArchive(to destination: URL) throws {
        try queue.sync {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: logURL.path) {
                try Data().write(to: logURL, options: .atomic)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [
                "-c", "-k", "--sequesterRsrc", "--keepParent",
                logDirectory.path, destination.path
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "Arbor.Diagnostics",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "ditto failed to export diagnostics"]
                )
            }
        }
    }

    func summary() -> String {
        queue.sync {
            let count = (try? fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil))?.count ?? 0
            return "local JSONL files: \(count); credentials and repository content are excluded"
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private func append(_ record: Record) throws {
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        var line = try encoder.encode(record)
        line.append(0x0A)
        let currentSize = (try? fileManager.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        if currentSize + line.count > maxBytes {
            for index in stride(from: retainedFiles - 1, through: 1, by: -1) {
                let source = logDirectory.appendingPathComponent("arbor.log.\(index)")
                let target = logDirectory.appendingPathComponent("arbor.log.\(index + 1)")
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                if fileManager.fileExists(atPath: source.path) { try fileManager.moveItem(at: source, to: target) }
            }
            let rotated = logDirectory.appendingPathComponent("arbor.log.1")
            if fileManager.fileExists(atPath: rotated.path) { try fileManager.removeItem(at: rotated) }
            if fileManager.fileExists(atPath: logURL.path) { try fileManager.moveItem(at: logURL, to: rotated) }
        }
        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: logURL, options: .atomic)
        }
    }
}
