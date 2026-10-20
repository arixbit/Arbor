import CoreServices
import SwiftUI


private func repositoryExternalVCSActionSnapshotPaths(
    _ action: RepositoryExternalVCSAction
) -> [String] {
    Array(Set(
        action.addPaths
            + action.stageAddPaths
            + action.removePaths
            + action.forceMoves.flatMap { [$0.oldPath, $0.newPath] }
    )).sorted()
}

private func repositoryExternalVCSFNV1a(_ bytes: some Sequence<UInt8>) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

private func repositoryExternalVCSFileDigest(at path: String) -> (UInt64, String)? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    var hash: UInt64 = 0xcbf29ce484222325
    var count: UInt64 = 0
    do {
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            count += UInt64(data.count)
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
        }
        return (count, String(format: "%016llx", hash))
    } catch {
        return nil
    }
}

func repositoryExternalVCSPathSnapshot(
    rootPath: String,
    relativePath: String
) -> RepositoryExternalVCSPathSnapshot {
    let absolutePath = URL(fileURLWithPath: rootPath)
        .standardizedFileURL
        .appendingPathComponent(relativePath)
        .standardizedFileURL
        .path
    let fileManager = FileManager.default
    if let destination = try? fileManager.destinationOfSymbolicLink(atPath: absolutePath) {
        let bytes = Array(destination.utf8)
        return RepositoryExternalVCSPathSnapshot(
            path: relativePath,
            kind: .symbolicLink,
            byteCount: UInt64(bytes.count),
            digest: repositoryExternalVCSFNV1a(bytes)
        )
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory) else {
        return RepositoryExternalVCSPathSnapshot(
            path: relativePath,
            kind: .missing,
            byteCount: nil,
            digest: nil
        )
    }
    if isDirectory.boolValue {
        return RepositoryExternalVCSPathSnapshot(
            path: relativePath,
            kind: .directory,
            byteCount: nil,
            digest: nil
        )
    }
    if let (byteCount, digest) = repositoryExternalVCSFileDigest(at: absolutePath) {
        return RepositoryExternalVCSPathSnapshot(
            path: relativePath,
            kind: .file,
            byteCount: byteCount,
            digest: digest
        )
    }
    return RepositoryExternalVCSPathSnapshot(
        path: relativePath,
        kind: .other,
        byteCount: nil,
        digest: nil
    )
}

func repositoryExternalVCSActionCapturingSnapshots(
    _ action: RepositoryExternalVCSAction,
    rootPath: String
) -> RepositoryExternalVCSAction {
    RepositoryExternalVCSAction(
        addPaths: action.addPaths,
        stageAddPaths: action.stageAddPaths,
        removePaths: action.removePaths,
        forceMoves: action.forceMoves,
        pathSnapshots: repositoryExternalVCSActionSnapshotPaths(action).map {
            repositoryExternalVCSPathSnapshot(rootPath: rootPath, relativePath: $0)
        }
    )
}

func repositoryExternalVCSActionMatchesSnapshots(
    _ action: RepositoryExternalVCSAction,
    rootPath: String
) -> Bool {
    let expectedPaths = repositoryExternalVCSActionSnapshotPaths(action)
    guard !expectedPaths.isEmpty,
          action.pathSnapshots.count == expectedPaths.count,
          action.pathSnapshots.allSatisfy(\.isVerifiable) else {
        return false
    }
    let current = expectedPaths.map {
        repositoryExternalVCSPathSnapshot(rootPath: rootPath, relativePath: $0)
    }
    return current == action.pathSnapshots
}
