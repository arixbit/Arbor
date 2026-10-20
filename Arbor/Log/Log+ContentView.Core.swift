import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

var showAuthorAndDateBinding: Binding<Bool> {
    Binding(
        get: {
            (logShowCommitColumns || logShowAuthorColumn)
                && (logShowCommitColumns || logShowDateColumn)
        },
        set: { visible in
            logShowCommitColumns = visible
            logShowAuthorColumn = visible
            logShowDateColumn = visible
        }
    )
}


var showAuthorColumnBinding: Binding<Bool> {
    Binding(
        get: { logShowCommitColumns || logShowAuthorColumn },
        set: { visible in
            logShowAuthorColumn = visible
            if !visible { logShowCommitColumns = false }
        }
    )
}


var showDateColumnBinding: Binding<Bool> {
    Binding(
        get: { logShowCommitColumns || logShowDateColumn },
        set: { visible in
            logShowDateColumn = visible
            if !visible { logShowCommitColumns = false }
        }
    )
}

}
