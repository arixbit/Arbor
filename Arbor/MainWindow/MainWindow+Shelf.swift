import SwiftUI
import AppKit


/// Root-scoped Shelf data used by the Commit workspace. The primary root is
/// still backed by the live workspace state; secondary roots keep their own
/// read/preview snapshot so a visible Shelf can never be mistaken for the
/// primary repository's Shelf.
struct ShelfRootSnapshot {
    let rootPath: String
    let shelves: [ShelveInfo]
    let deletedShelves: [ShelveInfo]
    let changeLists: [ChangeListInfo]

    init(
        rootPath: String,
        shelves: [ShelveInfo],
        deletedShelves: [ShelveInfo],
        changeLists: [ChangeListInfo] = []
    ) {
        self.rootPath = rootPath
        self.shelves = shelves
        self.deletedShelves = deletedShelves
        self.changeLists = changeLists
    }
}
