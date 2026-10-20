import SwiftUI
import AppKit
import UniformTypeIdentifiers


struct ShelfUnshelveRequest: Identifiable {
    let id = UUID()
    let name: String
    let paths: [String]?
    let rootPath: String
}

struct ShelfBatchUnshelveRequest: Identifiable {
    let id = UUID()
    let names: [String]
    let rootPath: String
}

struct ShelfMemberBatchUnshelveRequest: Identifiable {
    let id = UUID()
    let groups: [ShelfPathDeleteGroup]
    let rootPath: String
}
