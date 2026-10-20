import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension RebasedUnshelveDialog {
    /// MatchPatchPaths falls back to the project root when a new file has
    /// multiple equally good VFS candidates. Existing text files still use
    /// their best context match, with the project root already preferred by
    /// `discoverBaseMappings` on ties.
    nonisolated static func automaticallySelectedBaseMapping(
        patchFiles: [RebasedShelfPatchFile],
        candidates: [RebasedPatchBaseCandidate]
    ) -> RebasedPatchBaseCandidate? {
        guard let best = candidates.first else { return nil }
        guard patchFiles.allSatisfy({ $0.status == .added }) else { return best }

        let tied = candidates.filter { $0.contextScore == best.contextScore }
        guard tied.count > 1 else { return best }
        return tied.first(where: { $0.basePath.isEmpty })
    }

}
