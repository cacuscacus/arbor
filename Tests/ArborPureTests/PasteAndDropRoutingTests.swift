import XCTest

@testable import ArborPure

/// Guards the routing rules added for sidebar drops and cut/paste.
final class PasteDestinationResolverTests: XCTestCase {
    func testPastesIntoCurrentFolderWithoutSelection() {
        XCTAssertEqual(
            PasteDestinationResolver.resolve(selectedFolders: [], currentFolder: "/work"),
            "/work"
        )
    }

    func testPastesIntoTheOnlySelectedFolder() {
        XCTAssertEqual(
            PasteDestinationResolver.resolve(
                selectedFolders: ["/work/archive"],
                currentFolder: "/work"
            ),
            "/work/archive"
        )
    }

    func testMultipleSelectedFoldersFallBackToCurrent() {
        XCTAssertEqual(
            PasteDestinationResolver.resolve(
                selectedFolders: ["/work/a", "/work/b"],
                currentFolder: "/work"
            ),
            "/work"
        )
    }
}

final class SidebarDropRoutingTests: XCTestCase {
    func testDraggingAFavoriteAlwaysReorders() {
        XCTAssertEqual(
            SidebarDropRouting.decision(
                isDraggingFavorite: true,
                carriesFiles: true,
                canTransfer: true
            ),
            .reorderFavorites
        )
    }

    func testFileDragWithHandlerTransfersIntoTheFolder() {
        XCTAssertEqual(
            SidebarDropRouting.decision(
                isDraggingFavorite: false,
                carriesFiles: true,
                canTransfer: true
            ),
            .transferFiles
        )
    }

    func testFileDragWithoutHandlerFallsBackToFavoritesBehavior() {
        XCTAssertEqual(
            SidebarDropRouting.decision(
                isDraggingFavorite: false,
                carriesFiles: true,
                canTransfer: false
            ),
            .reorderFavorites
        )
    }

    func testDragWithoutFilesNeverTransfers() {
        XCTAssertEqual(
            SidebarDropRouting.decision(
                isDraggingFavorite: false,
                carriesFiles: false,
                canTransfer: true
            ),
            .reorderFavorites
        )
    }
}
