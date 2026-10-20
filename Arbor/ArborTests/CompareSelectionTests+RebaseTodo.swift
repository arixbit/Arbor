import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testPersistedRebaseActionKeepsStructuredSquashMessage() {
        let action = RebaseAction.squashWithMessage(message: "combined\n\nreviewed")
        let persisted = PersistedRebaseAction(action: action)

        XCTAssertEqual(persisted.kind, .squash)
        XCTAssertEqual(persisted.message, "combined\n\nreviewed")
        XCTAssertEqual(persisted.makeAction(), action)
    }

    func testRebaseTodoResetRestoresInitialActionsOrderAndMessages() {
        let initial = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "first", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .reword, commitId: "b", summary: "second", message: "edited", isMergeCommit: false, canSquashOrFixup: true)
        ]
        let current = [
            RebaseTodoItem(action: .drop, commitId: "b", summary: "second", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "a", summary: "first", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        XCTAssertEqual(
            resetRebaseTodoDraftItems(current: current, initial: initial),
            initial
        )
        XCTAssertEqual(
            resetRebaseTodoDraftItems(current: initial, initial: initial),
            initial
        )
    }

    func testPreparedRootRewordTodoChangesOnlySelectedRootAndPreservesMergeRows() {
        let todo = RebaseTodo(
            onto: "",
            items: [
                RebaseTodoItem(
                    action: .pick,
                    commitId: "root123",
                    summary: "root",
                    message: nil,
                    isMergeCommit: false,
                    canSquashOrFixup: false
                ),
                RebaseTodoItem(
                    action: .pick,
                    commitId: "merge456",
                    summary: "merge",
                    message: nil,
                    isMergeCommit: true,
                    canSquashOrFixup: false
                ),
                RebaseTodoItem(
                    action: .pick,
                    commitId: "post789",
                    summary: "post",
                    message: nil,
                    isMergeCommit: false,
                    canSquashOrFixup: false
                )
            ]
        )

        let prepared = preparedRootRewordTodo(
            todo,
            rootCommitID: "root",
            message: "new root\n\nbody"
        )

        XCTAssertEqual(prepared?.items[0].action, .reword)
        XCTAssertEqual(prepared?.items[0].message, "new root\n\nbody")
        XCTAssertEqual(prepared?.items[1].action, .pick)
        XCTAssertTrue(prepared?.items[1].isMergeCommit == true)
        XCTAssertNil(prepared?.items[2].message)
        XCTAssertEqual(todo.items[0].action, .pick)
        XCTAssertNil(todo.items[0].message)
    }

    func testPreparedRootRewordTodoRejectsMissingRoot() {
        let todo = RebaseTodo(
            onto: "",
            items: [
                RebaseTodoItem(
                    action: .pick,
                    commitId: "root123",
                    summary: "root",
                    message: nil,
                    isMergeCommit: false,
                    canSquashOrFixup: false
                )
            ]
        )

        XCTAssertNil(
            preparedRootRewordTodo(
                todo,
                rootCommitID: "missing",
                message: "new root"
            )
        )
    }

    func testRebaseTodoResetPreservesMergeTopologyMarker() {
        let initial = [
            RebaseTodoItem(
                action: .pick,
                commitId: "merge",
                summary: "merge feature",
                message: nil,
                isMergeCommit: true,
                canSquashOrFixup: false
            )
        ]
        let current = [
            RebaseTodoItem(
                action: .drop,
                commitId: "merge",
                summary: "merge feature",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: true
            )
        ]

        let restored = resetRebaseTodoDraftItems(current: current, initial: initial)
        XCTAssertEqual(restored, initial)
        XCTAssertTrue(restored.first?.isMergeCommit == true)
    }

    func testRebaseTodoSquashFixupRequiresKeptPredecessor() {
        let initial = [
            RebaseTodoItem(
                action: .pick,
                commitId: "parent",
                summary: "parent",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: false
            ),
            RebaseTodoItem(
                action: .pick,
                commitId: "child",
                summary: "child",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: true
            )
        ]

        XCTAssertTrue(
            rebaseTodoCanSquashOrFixup(items: initial, index: 1, preserveMerges: true)
        )

        var dropped = initial
        dropped[0].action = .drop
        XCTAssertFalse(
            rebaseTodoCanSquashOrFixup(items: dropped, index: 1, preserveMerges: true)
        )
        normalizeRebaseTodoActions(&dropped, preserveMerges: true)
        XCTAssertEqual(dropped[1].action, .pick)
    }

    func testPreserveMergeTodoReorderStaysInsideNativeBranchSegments() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "a", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "b", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "merge", summary: "merge", message: nil, isMergeCommit: true, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "c", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        XCTAssertEqual(
            rebaseTodoPreserveMergeSegmentRanges(items).map { Array($0) },
            [[0, 1], [3]]
        )

        let withinSegment = moveRebaseTodoItems(
            items,
            selectedIndices: [1],
            requestedIndex: 1,
            by: -1
        )
        XCTAssertTrue(
            rebaseTodoPreserveMergeReorderIsSafe(original: items, updated: withinSegment)
        )
        XCTAssertTrue(
            rebaseTodoCanMove(
                items,
                selectedIndices: [1],
                requestedIndex: 1,
                by: -1,
                preserveMerges: true
            )
        )

        let acrossBoundary = moveRebaseTodoItems(
            items,
            selectedIndices: [1],
            requestedIndex: 1,
            by: 1
        )
        XCTAssertFalse(
            rebaseTodoPreserveMergeReorderIsSafe(original: items, updated: acrossBoundary)
        )
        XCTAssertFalse(
            rebaseTodoCanMove(
                items,
                selectedIndices: [1],
                requestedIndex: 1,
                by: 1,
                preserveMerges: true
            )
        )
    }

    func testPreserveMergeTodoReorderCannotMoveMergeAnchor() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "a", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "merge", summary: "merge", message: nil, isMergeCommit: true, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "b", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        XCTAssertFalse(
            rebaseTodoCanMove(
                items,
                selectedIndices: [1],
                requestedIndex: 1,
                by: -1,
                preserveMerges: true
            )
        )
    }

    func testMultiRootPreserveMergeOrderChangeIsScopedPerRepository() {
        let rootA = [
            RebaseTodoItem(action: .pick, commitId: "a1", summary: "a1", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "a2", summary: "a2", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "am", summary: "merge", message: nil, isMergeCommit: true, canSquashOrFixup: false)
        ]
        var rootAReordered = rootA
        rootAReordered.swapAt(0, 1)
        let rootB = [
            RebaseTodoItem(action: .pick, commitId: "b1", summary: "b1", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        XCTAssertTrue(
            rebaseTodoPreserveMergeOrderChanged(
                initial: rootA,
                current: rootAReordered,
                preserveMerges: true
            )
        )
        XCTAssertFalse(
            rebaseTodoPreserveMergeOrderChanged(
                initial: rootB,
                current: rootB,
                preserveMerges: true
            )
        )
        XCTAssertFalse(
            rebaseTodoPreserveMergeOrderChanged(
                initial: rootA,
                current: rootAReordered,
                preserveMerges: false
            )
        )
    }

    func testRebaseTodoActionClearsMessageOutsideRewordAndSquash() {
        var item = RebaseTodoItem(
            action: .reword,
            commitId: "commit",
            summary: "message",
            message: "edited",
            isMergeCommit: false,
            canSquashOrFixup: true
        )

        setRebaseTodoAction(&item, action: .pick)
        XCTAssertNil(item.message)

        item.message = "combined"
        setRebaseTodoAction(&item, action: .squash)
        XCTAssertEqual(item.message, "combined")

        setRebaseTodoAction(&item, action: .drop)
        XCTAssertNil(item.message)
    }

    func testRebaseTodoActionDetachesChangedSquashChildAndPreservesGroup() {
        var items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .fixup, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        XCTAssertTrue(applyRebaseTodoAction(&items, at: 1, action: .edit))
        XCTAssertEqual(items.map(\.commitId), ["a", "c", "b"])
        XCTAssertEqual(items.map(\.action), [.pick, .fixup, .edit])
        XCTAssertFalse(rebaseTodoCanReword(items: items, index: 1))
        XCTAssertTrue(rebaseTodoCanReword(items: items, index: 2))
    }

    func testRebaseTodoDropOnSquashRootDropsTheWholeGroup() {
        var items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: "combined", isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .fixup, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        XCTAssertTrue(applyRebaseTodoAction(&items, at: 0, action: .drop))
        XCTAssertEqual(items.map(\.action), [.drop, .drop, .drop])
        XCTAssertTrue(items.allSatisfy { $0.message == nil })
    }

    func testRebaseTodoEditHistorySupportsUndoRedoAndCoalescesMessageTyping() {
        let initial = [
            RebaseTodoItem(
                action: .pick,
                commitId: "a",
                summary: "first",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: false
            ),
            RebaseTodoItem(
                action: .pick,
                commitId: "b",
                summary: "second",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: true
            )
        ]
        var history = RebaseTodoEditHistory(initial: initial)
        var reworded = initial
        reworded[1].action = .reword
        reworded[1].message = "first edit"
        history.record(reworded, change: .structural)

        var reordered = reworded
        reordered.swapAt(0, 1)
        history.record(reordered, change: .structural)
        XCTAssertEqual(history.undo(), reworded)
        XCTAssertEqual(history.redo(), reordered)

        var typed = reordered
        typed[1].message = "c"
        history.record(typed, change: .message(commitID: "a"))
        typed[1].message = "combined"
        history.record(typed, change: .message(commitID: "a"))
        XCTAssertEqual(history.states.count, 4)
        XCTAssertEqual(history.undo(), reordered)
        XCTAssertTrue(history.canRedo)
    }

    func testRebaseTodoEditHistoryCapsStatesAndDropsRedoAfterBranching() {
        let initial = [
            RebaseTodoItem(
                action: .pick,
                commitId: "a",
                summary: "initial",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: false
            )
        ]
        var history = RebaseTodoEditHistory(initial: initial)
        for number in 1...12 {
            var next = initial
            next[0].summary = "state \(number)"
            history.record(next, change: .structural)
        }

        XCTAssertEqual(history.states.count, RebaseTodoEditHistory.maximumStateCount)
        XCTAssertEqual(history.current.first?.summary, "state 12")
        _ = history.undo()
        var branch = history.current
        branch[0].summary = "branched"
        history.record(branch, change: .structural)
        XCTAssertFalse(history.canRedo)
    }

    func testRebaseTodoDiscardConfirmationTracksStructuredAndRawChanges() {
        let initial = [
            RebaseTodoItem(
                action: .pick,
                commitId: "a",
                summary: "initial",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: false
            )
        ]

        XCTAssertFalse(
            rebaseTodoHasUnsavedChanges(current: initial, initial: initial)
        )
        var edited = initial
        edited[0].action = .reword
        XCTAssertTrue(
            rebaseTodoHasUnsavedChanges(current: edited, initial: initial)
        )
        XCTAssertTrue(
            rebaseTodoHasUnsavedChanges(
                current: initial,
                initial: initial,
                rawTodo: "pick a initial"
            )
        )
    }

    func testRebaseTodoUniteSquashMovesNonContiguousSelectionIntoOneGroup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "d", summary: "D", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let united = uniteRebaseTodoItems(
            items,
            selectedIndices: [0, 2],
            action: .squash,
            preserveMerges: false
        )

        XCTAssertEqual(united?.map(\.commitId), ["a", "c", "b", "d"])
        XCTAssertEqual(united?.map(\.action), [.pick, .squash, .pick, .pick])
        XCTAssertEqual(united?[1].message, "A\n\nC")
    }

    func testRebaseTodoMovePreservesNonContiguousSelectionIdentity() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "d", summary: "D", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "e", summary: "E", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let movedUp = moveRebaseTodoItems(
            items,
            selectedIndices: [1, 3],
            requestedIndex: 1,
            by: -1
        )
        XCTAssertEqual(movedUp.map(\.commitId), ["b", "a", "d", "c", "e"])

        let movedDown = moveRebaseTodoItems(
            items,
            selectedIndices: [1, 3],
            requestedIndex: 3,
            by: 1
        )
        XCTAssertEqual(movedDown.map(\.commitId), ["a", "c", "b", "e", "d"])
    }

    func testRebaseTodoDragMovePreservesSourceOrderAndDestinationSemantics() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "d", summary: "D", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "e", summary: "E", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let moved = moveRebaseTodoRows(items, from: IndexSet([1, 3]), to: 5)
        XCTAssertEqual(moved.map(\.commitId), ["a", "c", "e", "b", "d"])

        let movedUp = moveRebaseTodoRows(items, from: IndexSet([1, 3]), to: 1)
        XCTAssertEqual(movedUp.map(\.commitId), ["a", "b", "d", "c", "e"])
    }

    func testRebaseTodoMoveDetachesChildWhenLeavingGroup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .fixup, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "d", summary: "D", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let movedUp = moveRebaseTodoItems(
            items,
            selectedIndices: [1],
            requestedIndex: 1,
            by: -1
        )
        XCTAssertEqual(movedUp.map(\.commitId), ["b", "a", "c", "d"])
        XCTAssertEqual(movedUp.map(\.action), [.pick, .pick, .fixup, .pick])

        let movedDown = moveRebaseTodoItems(
            items,
            selectedIndices: [2],
            requestedIndex: 2,
            by: 1
        )
        XCTAssertEqual(movedDown.map(\.commitId), ["a", "b", "d", "c"])
        XCTAssertEqual(movedDown.map(\.action), [.pick, .squash, .pick, .pick])
    }

    func testRebaseTodoMoveKeepsSquashGroupTogether() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let moved = moveRebaseTodoItems(
            items,
            selectedIndices: [0],
            requestedIndex: 0,
            by: 1
        )
        XCTAssertEqual(moved.map(\.commitId), ["c", "a", "b"])
        XCTAssertEqual(moved.map(\.action), [.pick, .pick, .squash])
    }

    func testRebaseTodoMoveJoinsExistingGroupAtBoundary() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "d", summary: "D", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let moved = moveRebaseTodoItems(
            items,
            selectedIndices: [0],
            requestedIndex: 0,
            by: 1
        )
        XCTAssertEqual(moved.map(\.commitId), ["b", "a", "c", "d"])
        XCTAssertEqual(moved.map(\.action), [.pick, .fixup, .squash, .pick])
    }

    func testRebaseTodoDragMovesWholeSquashGroup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let moved = moveRebaseTodoRows(items, from: IndexSet([0]), to: 3)
        XCTAssertEqual(moved.map(\.commitId), ["c", "a", "b"])
        XCTAssertEqual(moved.map(\.action), [.pick, .pick, .squash])
    }

    func testNativeRebaseTodoPreviewParsesCommitAndControlRowsWithoutRejectingUnknownSyntax() {
        let rows = parseNativeRebaseTodoPreview(
            """
            pick abc123 First commit
            label branch-point
            reset onto
            merge -C deadbeef branch-point
            exec make test
            break
            update-ref refs/heads/topic
            # Git-generated comment
            future-command newer-git-syntax
            """
        )

        XCTAssertEqual(rows.count, 9)
        if case let .commit(command, commitID, subject) = rows[0].kind {
            XCTAssertEqual(command, "pick")
            XCTAssertEqual(commitID, "abc123")
            XCTAssertEqual(subject, "First commit")
        } else {
            XCTFail("expected a commit row")
        }
        if case let .control(command, arguments) = rows[1].kind {
            XCTAssertEqual(command, "label")
            XCTAssertEqual(arguments, "branch-point")
        } else {
            XCTFail("expected a label control row")
        }
        if case let .control(command, arguments) = rows[4].kind {
            XCTAssertEqual(command, "exec")
            XCTAssertEqual(arguments, "make test")
        } else {
            XCTFail("expected an exec control row")
        }
        XCTAssertEqual(rows[7].kind, .comment)
        XCTAssertEqual(rows[8].kind, .invalid)
    }

    func testNativeRebaseTodoControlEditingChangesOnlyTheTargetLine() {
        let original = "pick abc First\n  label old-point\n# keep this comment\nexec make test\n"
        let updated = updateNativeRebaseTodoControlLine(
            original,
            lineNumber: 2,
            command: "label",
            arguments: "new-point"
        )

        XCTAssertEqual(
            updated,
            "pick abc First\n  label new-point\n# keep this comment\nexec make test\n"
        )
        XCTAssertEqual(nativeRebaseTodoControlArguments(updated, lineNumber: 2), "new-point")
        XCTAssertNil(nativeRebaseTodoControlArguments(updated, lineNumber: 1))

        let crlf = "label old\r\n# keep CRLF\r\n"
        XCTAssertEqual(
            updateNativeRebaseTodoControlLine(
                crlf,
                lineNumber: 1,
                command: "label",
                arguments: "new"
            ),
            "label new\r\n# keep CRLF\r\n"
        )
        XCTAssertEqual(
            updateNativeRebaseTodoControlLine(
                crlf,
                lineNumber: 4,
                command: "label",
                arguments: "ignored"
            ),
            crlf
        )
    }

    func testNativeRebaseTodoControlRowsSupportTypeConversionAndStableReordering() {
        let original = "pick abc First\r\n# keep this comment\r\nlabel old\r\nexec make test\r\n"
        let converted = updateNativeRebaseTodoControlLine(
            original,
            lineNumber: 3,
            command: "break",
            arguments: "ignored"
        )

        XCTAssertEqual(
            converted,
            "pick abc First\r\n# keep this comment\r\nbreak\r\nexec make test\r\n"
        )
        XCTAssertEqual(nativeRebaseTodoControlCommand(converted, lineNumber: 3), "break")
        XCTAssertEqual(nativeRebaseTodoControlArguments(converted, lineNumber: 3), "")

        let movedUp = moveNativeRebaseTodoControlLine(
            converted,
            lineNumber: 4,
            by: -1
        )
        XCTAssertEqual(
            movedUp,
            "pick abc First\r\n# keep this comment\r\nexec make test\r\nbreak\r\n"
        )
        XCTAssertEqual(nativeRebaseTodoControlCommand(movedUp, lineNumber: 3), "exec")
        XCTAssertEqual(nativeRebaseTodoControlCommand(movedUp, lineNumber: 4), "break")
        XCTAssertEqual(
            moveNativeRebaseTodoControlLine(movedUp, lineNumber: 1, by: 1),
            movedUp
        )
        XCTAssertEqual(
            moveNativeRebaseTodoControlLine(movedUp, lineNumber: 2, by: 1),
            movedUp
        )

        let unknownSyntax = "label point\r\nfuture-command newer-git-syntax\r\n"
        XCTAssertEqual(
            moveNativeRebaseTodoControlLine(unknownSyntax, lineNumber: 1, by: 1),
            "future-command newer-git-syntax\r\nlabel point\r\n"
        )
    }

    func testRebaseTodoCommandsHelpUsesGitCommandNames() {
        XCTAssertEqual(
            [
                RebaseTodoAction.pick,
                .reword,
                .edit,
                .squash,
                .fixup,
                .drop
            ].map(rebaseTodoActionCommand),
            ["pick", "reword", "edit", "squash", "fixup", "drop"]
        )
    }

    func testRebaseTodoContextSelectionKeepsMultiSelectionOnlyWhenInvokedInsideIt() {
        XCTAssertEqual(
            rebaseTodoContextSelection(selectedIndices: [1, 3], row: 3),
            [1, 3]
        )
        XCTAssertEqual(
            rebaseTodoContextSelection(selectedIndices: [1, 3], row: 2),
            [2]
        )
        XCTAssertEqual(
            rebaseTodoContextSelection(selectedIndices: [], row: 0),
            [0]
        )
    }

    func testRebaseStartNeedsNoopConfirmationOnlyForInteractiveEmptyRange() {
        XCTAssertTrue(rebaseStartNeedsNoopConfirmation(interactive: true, rangeCount: 0))
        XCTAssertFalse(rebaseStartNeedsNoopConfirmation(interactive: true, rangeCount: 2))
        XCTAssertFalse(rebaseStartNeedsNoopConfirmation(interactive: false, rangeCount: 0))
    }

    func testRebaseHelpLinksToGitDocumentation() {
        XCTAssertEqual(
            rebaseHelpDocumentationURL.absoluteString,
            "https://git-scm.com/docs/git-rebase"
        )
    }

    func testMultiRootRebaseNoopRootsIgnoreFailedDrafts() {
        let drafts = [
            MultiRootRebaseTodoDraft(
                rootPath: "/workspace/noop",
                displayName: "noop",
                items: [],
                rawTodo: nil,
                loadError: nil
            ),
            MultiRootRebaseTodoDraft(
                rootPath: "/workspace/active",
                displayName: "active",
                items: [
                    RebaseTodoItem(
                        action: .pick,
                        commitId: "commit",
                        summary: "commit",
                        message: nil,
                        isMergeCommit: false,
                        canSquashOrFixup: false
                    )
                ],
                rawTodo: nil,
                loadError: nil
            ),
            MultiRootRebaseTodoDraft(
                rootPath: "/workspace/failed",
                displayName: "failed",
                items: [],
                rawTodo: nil,
                loadError: "range failed"
            )
        ]

        XCTAssertEqual(
            multiRootRebaseNoopRootPaths(drafts),
            ["/workspace/noop"]
        )
    }

    func testMultiRootRebaseDetailsStayInRootTodoOrderAndUseFocusedCommitWhenUnselected() {
        let draft = MultiRootRebaseTodoDraft(
            rootPath: "/workspace/root-b",
            displayName: "root-b",
            items: [
                RebaseTodoItem(action: .pick, commitId: "b1", summary: "B1", message: nil, isMergeCommit: false, canSquashOrFixup: false),
                RebaseTodoItem(action: .pick, commitId: "b2", summary: "B2", message: nil, isMergeCommit: false, canSquashOrFixup: true),
                RebaseTodoItem(action: .pick, commitId: "b3", summary: "B3", message: nil, isMergeCommit: false, canSquashOrFixup: true)
            ],
            rawTodo: nil,
            loadError: nil
        )

        XCTAssertEqual(
            multiRootRebaseDetailCommitIDs(
                draft: draft,
                selectedIDs: ["b3", "b1"],
                focusedID: "b3"
            ),
            ["b1", "b3"]
        )
        XCTAssertEqual(
            multiRootRebaseDetailCommitIDs(
                draft: draft,
                selectedIDs: [],
                focusedID: "b2"
            ),
            ["b2"]
        )
    }

    func testMultiRootRebaseSessionDecodesLegacyRootWithoutStructuredOrder() throws {
        let legacy = Data(#"""
        {
            "rootPath":"/workspace/root",
            "displayName":"root",
            "branch":"main",
            "onto":"base",
            "actions":[],
            "rawTodo":null,
            "preserveMerges":true,
            "autoSquash":false,
            "keepEmpty":false,
            "updateRefs":false,
            "root":false,
            "savePolicyRaw":null,
            "protectionCommitID":null,
            "state":"pending",
            "initialHead":null,
            "expectedHead":null,
            "initialBranch":null,
            "message":""
        }
        """#.utf8)

        let root = try JSONDecoder().decode(MultiRootRebaseSessionRoot.self, from: legacy)
        XCTAssertNil(root.orderedCommitIds)
        XCTAssertEqual(root.makeSpec().orderedCommitIds, [])
    }

    func testRebaseTodoUniteFixupUsesThePreviousKeptRootForSingleSelection() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let united = uniteRebaseTodoItems(
            items,
            selectedIndices: [2],
            action: .fixup,
            preserveMerges: false
        )

        XCTAssertEqual(united?.map(\.commitId), ["a", "b", "c"])
        XCTAssertEqual(united?.map(\.action), [.pick, .pick, .fixup])
        XCTAssertNil(united?[2].message)
    }

    func testRebaseTodoUnitePreservesExistingGroupMessageWhenAddingFixup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: "A\n\nB", isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let united = uniteRebaseTodoItems(
            items,
            selectedIndices: [2],
            action: .fixup,
            preserveMerges: false
        )

        XCTAssertEqual(united?.map(\.action), [.pick, .squash, .fixup])
        XCTAssertEqual(united?[1].message, "A\n\nB")
    }

    func testRebaseTodoUniteRejectsSelectionAlreadyInsideOneGroup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .fixup, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .fixup, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        XCTAssertNil(
            uniteRebaseTodoItems(
                items,
                selectedIndices: [1, 2],
                action: .squash,
                preserveMerges: false
            )
        )
    }

    func testRebaseTodoUniteNormalizesSelectedDropIntoKeptGroup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .drop, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let united = uniteRebaseTodoItems(
            items,
            selectedIndices: [1],
            action: .fixup,
            preserveMerges: false
        )

        XCTAssertEqual(united?.map(\.action), [.pick, .fixup, .pick])
    }

    func testRebaseTodoUniteRejectsMergePreservingStructuredSelection() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "merge", summary: "merge", message: nil, isMergeCommit: true, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "child", summary: "child", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        XCTAssertNil(
            uniteRebaseTodoItems(
                items,
                selectedIndices: [0, 1],
                action: .squash,
                preserveMerges: true
            )
        )
    }

    func testRebaseTodoUniteAllowsOnlyContiguousPreserveMergeBranchSegments() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "root", summary: "root", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "feature-1", summary: "feature 1", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "feature-2", summary: "feature 2", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "merge", summary: "merge", message: nil, isMergeCommit: true, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "post-merge", summary: "post merge", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        let united = uniteRebaseTodoItems(
            items,
            selectedIndices: [1, 2],
            action: .squash,
            preserveMerges: true
        )
        XCTAssertEqual(united?.map(\.action), [.pick, .pick, .squash, .pick, .pick])

        XCTAssertNil(
            uniteRebaseTodoItems(
                items,
                selectedIndices: [0, 2],
                action: .fixup,
                preserveMerges: true
            )
        )
    }

    func testRootRebaseAllowsAnEmptyOntoButNonRootRequiresOne() {
        XCTAssertTrue(
            rebaseInputsCanLoadRange(onto: "", branch: "main", root: true)
        )
        XCTAssertTrue(
            rebaseInputsCanLoadRange(onto: "origin/main", branch: "main", root: true)
        )
        XCTAssertFalse(
            rebaseInputsCanLoadRange(onto: "", branch: "main", root: false)
        )
        XCTAssertFalse(
            rebaseInputsCanLoadRange(onto: "origin/main", branch: "", root: true)
        )
    }
}
