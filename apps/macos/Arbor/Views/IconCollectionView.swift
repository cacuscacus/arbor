import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder-like icon browser backed by AppKit `NSCollectionView` (true virtualization).
struct IconCollectionView<MenuContent: View, EmptyMenu: View>: NSViewRepresentable {
    let entries: [FileEntry]
    @Binding var selection: Set<URL>
    @Binding var renamingURL: URL?
    @Binding var renameDraft: String
    var iconMetrics: IconViewMetrics
    var currentFolder: URL?
    var dragState: FileDragState
    var onOpen: (FileEntry) -> Void
    var onTransfer: ([URL], URL, FileTransferOperation) -> Void
    var onRequestRename: (FileEntry) -> Void
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    var onDeleteSelection: (() -> Void)? = nil
    @ViewBuilder var contextMenu: (FileEntry) -> MenuContent
    @ViewBuilder var emptySpaceMenu: () -> EmptyMenu

    func makeCoordinator() -> IconCollectionCoordinator {
        IconCollectionCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.install(from: self)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        // Vertical scroller required for Tahoe scroll-edge/underlap on AppKit scroll views.
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        // Content rests below the toolbar glass but can scroll underneath with soft edge.
        scroll.automaticallyAdjustsContentInsets = true
        scroll.contentInsets = NSEdgeInsets()

        let collection = IconCollectionNSView()
        collection.eventHandler = coordinator
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        // Class registration must use the ObjC-visible item type.
        collection.register(IconCollectionItem.self, forItemWithIdentifier: IconCollectionItem.identifier)
        assert(
            NSClassFromString("ArborIconItem") != nil,
            "IconCollectionItem must be visible to ObjC as ArborIconItem"
        )

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collection.collectionViewLayout = layout
        collection.dataSource = coordinator
        collection.delegate = coordinator

        scroll.documentView = collection
        coordinator.collectionView = collection
        coordinator.applyMetrics()
        coordinator.reload(entries: entries, preserveSelection: false)
        FileIcon.prefetch(urls: entries.map(\.id), size: iconMetrics.iconPoints)
        collection.registerForDraggedTypes([.fileURL])
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.install(from: self)
        if let collection = scrollView.documentView as? IconCollectionNSView {
            // Defend against SwiftUI recreating the document view without our register call.
            collection.register(IconCollectionItem.self, forItemWithIdentifier: IconCollectionItem.identifier)
            collection.eventHandler = coordinator
            coordinator.collectionView = collection
        }
        coordinator.applyMetrics()
        coordinator.syncEntries(entries)
        coordinator.syncSelection(selection)
        coordinator.syncRename(renamingURL: renamingURL, draft: renameDraft)
    }
}

// MARK: - Coordinator

@MainActor
final class IconCollectionCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, IconCollectionEventHandling, IconItemActionHandling {
    weak var collectionView: IconCollectionNSView?

    private var entries: [FileEntry] = []
    private var indexByURL: [URL: Int] = [:]
    private var isApplyingSelection = false
    private var lastMetrics: IconViewMetrics?

    private var getSelection: (() -> Set<URL>) = { [] }
    private var setSelection: ((Set<URL>) -> Void) = { _ in }
    private var getRenameDraft: (() -> String) = { "" }
    private var setRenameDraft: ((String) -> Void) = { _ in }
    private var iconMetrics = IconViewMetrics(iconPoints: IconViewMetrics.default)
    private var dragState: FileDragState?
    private var onOpen: ((FileEntry) -> Void)?
    private var onRequestRename: ((FileEntry) -> Void)?
    private var onCommitRename: (() -> Void)?
    private var onCancelRename: (() -> Void)?
    private var onTransfer: (([URL], URL, FileTransferOperation) -> Void)?
    private var onDeleteSelection: (() -> Void)?
    private var currentFolder: URL?
    private var makeItemMenu: ((FileEntry) -> AnyView)?
    private var makeEmptyMenu: (() -> AnyView)?
    private var renamingURL: URL?

    private var selection: Set<URL> { getSelection() }

    func install<MenuContent: View, EmptyMenu: View>(from parent: IconCollectionView<MenuContent, EmptyMenu>) {
        getSelection = { parent.selection }
        setSelection = { parent.selection = $0 }
        getRenameDraft = { parent.renameDraft }
        setRenameDraft = { parent.renameDraft = $0 }
        iconMetrics = parent.iconMetrics
        dragState = parent.dragState
        onOpen = parent.onOpen
        onRequestRename = parent.onRequestRename
        onCommitRename = parent.onCommitRename
        onCancelRename = parent.onCancelRename
        onTransfer = parent.onTransfer
        onDeleteSelection = parent.onDeleteSelection
        currentFolder = parent.currentFolder
        renamingURL = parent.renamingURL
        makeItemMenu = { AnyView(parent.contextMenu($0)) }
        makeEmptyMenu = { AnyView(parent.emptySpaceMenu()) }
    }

    func applyMetrics() {
        guard let collectionView,
              let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout
        else { return }
        guard lastMetrics != iconMetrics else { return }
        lastMetrics = iconMetrics
        layout.itemSize = NSSize(width: iconMetrics.cellWidth, height: iconMetrics.cellHeight)
        layout.minimumInteritemSpacing = iconMetrics.gridSpacing
        layout.minimumLineSpacing = iconMetrics.gridSpacing
        layout.invalidateLayout()
    }

    func syncEntries(_ next: [FileEntry]) {
        let oldIDs = entries.map(\.id)
        let newIDs = next.map(\.id)
        guard oldIDs != newIDs else {
            if entries != next {
                entries = next
                rebuildIndex()
                refreshVisibleItems()
            }
            return
        }
        reload(entries: next, preserveSelection: true)
        FileIcon.prefetch(urls: newIDs, size: iconMetrics.iconPoints)
    }

    func reload(entries next: [FileEntry], preserveSelection: Bool) {
        let previous = preserveSelection ? selection : []
        entries = next
        rebuildIndex()
        collectionView?.reloadData()
        if preserveSelection {
            let valid = previous.intersection(Set(next.map(\.id)))
            if valid != selection {
                setSelection(valid)
            }
            applySelectionIndexPaths(valid)
        }
    }

    func syncSelection(_ selection: Set<URL>) {
        applySelectionIndexPaths(selection)
    }

    func syncRename(renamingURL: URL?, draft: String) {
        self.renamingURL = renamingURL
        guard let collectionView else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let item = collectionView.item(at: indexPath) as? IconCollectionItem else { continue }
            let entryID = entries.indices.contains(indexPath.item) ? entries[indexPath.item].id : nil
            item.setRenaming(entryID != nil && entryID == renamingURL, draft: draft)
        }
    }

    private func rebuildIndex() {
        var map: [URL: Int] = [:]
        map.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            map[entry.id] = index
        }
        indexByURL = map
    }

    private func refreshVisibleItems() {
        guard let collectionView else { return }
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let item = collectionView.item(at: indexPath) as? IconCollectionItem,
                  entries.indices.contains(indexPath.item)
            else { continue }
            let entry = entries[indexPath.item]
            item.configure(
                entry: entry,
                metrics: iconMetrics,
                selected: selection.contains(entry.id),
                renaming: renamingURL == entry.id,
                renameDraft: getRenameDraft(),
                actions: self
            )
        }
    }

    private func applySelectionIndexPaths(_ selection: Set<URL>) {
        guard let collectionView else { return }
        isApplyingSelection = true
        defer { isApplyingSelection = false }

        var paths = Set<IndexPath>()
        for url in selection {
            if let index = indexByURL[url] {
                paths.insert(IndexPath(item: index, section: 0))
            }
        }
        if collectionView.selectionIndexPaths != paths {
            collectionView.selectionIndexPaths = paths
        }
        // Update chrome only — avoid reconfigure/reload icons on every selection tick.
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let item = collectionView.item(at: indexPath) as? IconCollectionItem,
                  entries.indices.contains(indexPath.item)
            else { continue }
            item.isSelected = selection.contains(entries[indexPath.item].id)
        }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: IconCollectionItem.identifier,
            for: indexPath
        ) as! IconCollectionItem
        let entry = entries[indexPath.item]
        item.configure(
            entry: entry,
            metrics: iconMetrics,
            selected: selection.contains(entry.id),
            renaming: renamingURL == entry.id,
            renameDraft: getRenameDraft(),
            actions: self
        )
        if let makeItemMenu {
            item.view.menu = NSHostingMenu(rootView: makeItemMenu(entry))
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        publishSelection(from: collectionView)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        publishSelection(from: collectionView)
    }

    private func publishSelection(from collectionView: NSCollectionView) {
        guard !isApplyingSelection else { return }
        let urls = Set(collectionView.selectionIndexPaths.compactMap { path -> URL? in
            entries.indices.contains(path.item) ? entries[path.item].id : nil
        })
        if urls != selection {
            setSelection(urls)
        }
        // Collection view already updates `isSelected` on items.
    }

    func clearSelection() {
        setSelection([])
        applySelectionIndexPaths([])
    }

    func selectMarquee(indexPaths: Set<IndexPath>, additive: Bool) {
        let urls = Set(indexPaths.compactMap { path -> URL? in
            entries.indices.contains(path.item) ? entries[path.item].id : nil
        })
        if additive {
            var next = selection
            next.formUnion(urls)
            setSelection(next)
        } else {
            setSelection(urls)
        }
        applySelectionIndexPaths(selection)
    }

    func emptyMenu() -> NSMenu {
        if let makeEmptyMenu {
            return NSHostingMenu(rootView: makeEmptyMenu())
        }
        return NSMenu()
    }

    func open(entry: FileEntry) { onOpen?(entry) }
    func requestRename(entry: FileEntry) { onRequestRename?(entry) }
    func commitRename() { onCommitRename?() }
    func cancelRename() { onCancelRename?() }
    func updateRenameDraft(_ text: String) { setRenameDraft(text) }

    func beginDrag(anchor: FileEntry) -> [URL] {
        guard let dragState else { return [anchor.id] }
        if !selection.contains(anchor.id) {
            setSelection([anchor.id])
            applySelectionIndexPaths([anchor.id])
        }
        return dragState.beginDragging(anchor: anchor.id, selection: selection)
    }

    func endDrag() { dragState?.clear() }

    func dropURLs(_ urls: [URL], onto entry: FileEntry, copy: Bool) {
        guard entry.isBrowsable else { return }
        onTransfer?(urls, entry.id, copy ? .copy : .move)
    }

    func openSelection() {
        let selected = selection.compactMap { url in entries.first { $0.id == url } }
        guard let first = selected.first else { return }
        if selected.count == 1 {
            onOpen?(first)
        } else {
            for entry in selected where !entry.isBrowsable {
                onOpen?(entry)
            }
        }
    }

    func deleteSelection() {
        onDeleteSelection?()
    }

    // MARK: Collection drag-and-drop (drop onto folders)

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        let index = proposedDropIndexPath.pointee.item
        guard entries.indices.contains(index), entries[index].isBrowsable else {
            proposedDropOperation.pointee = .before
            return []
        }
        proposedDropOperation.pointee = .on
        return draggingInfo.draggingSourceOperationMask.intersection(
            NSEvent.modifierFlags.contains(.option) ? .copy : .move
        )
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard dropOperation == .on,
              entries.indices.contains(indexPath.item),
              entries[indexPath.item].isBrowsable
        else { return false }

        let urls = Self.readFileURLs(from: draggingInfo.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        let copy = NSEvent.modifierFlags.contains(.option)
            || draggingInfo.draggingSourceOperationMask.contains(.copy)
        dropURLs(urls, onto: entries[indexPath.item], copy: copy)
        return true
    }

    private static func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.compactMap { item in
            if let str = item.string(forType: .fileURL), let url = URL(string: str) {
                return url
            }
            return nil
        }
    }
}

// MARK: - Collection view

protocol IconCollectionEventHandling: AnyObject {
    func clearSelection()
    func selectMarquee(indexPaths: Set<IndexPath>, additive: Bool)
    func emptyMenu() -> NSMenu
    func openSelection()
    func deleteSelection()
}

final class IconCollectionNSView: NSCollectionView {
    weak var eventHandler: IconCollectionEventHandling?

    private var marqueeStart: CGPoint?
    private var marqueeLayer: CAShapeLayer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        menu = eventHandler?.emptyMenu()
        registerForDraggedTypes([.fileURL])
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // When AppKit owns first responder, SwiftUI onKeyPress may not fire.
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            eventHandler?.openSelection()
        case 51, 117: // Delete / Forward Delete
            eventHandler?.deleteSelection()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Layout cell frames are larger than Finder hit targets. Only treat icon/label
        // as “on item”; padding starts marquee (precise collision like before).
        if let indexPath = indexPathForItem(at: point),
           let item = item(at: indexPath) as? IconCollectionItem
        {
            let local = item.view.convert(point, from: self)
            if item.interactiveContains(local) {
                window?.makeFirstResponder(self)
                marqueeStart = nil
                super.mouseDown(with: event)
                return
            }
        }

        window?.makeFirstResponder(self)
        if !event.modifierFlags.contains(.command) {
            eventHandler?.clearSelection()
        }
        marqueeStart = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = marqueeStart else {
            super.mouseDragged(with: event)
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        updateMarquee(rect)
        eventHandler?.selectMarquee(
            indexPaths: indexPathsForItems(in: rect),
            additive: event.modifierFlags.contains(.command)
        )
    }

    override func mouseUp(with event: NSEvent) {
        marqueeStart = nil
        clearMarquee()
        super.mouseUp(with: event)
    }

    private func updateMarquee(_ rect: CGRect) {
        wantsLayer = true
        if marqueeLayer == nil {
            let layer = CAShapeLayer()
            layer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            layer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            layer.lineWidth = 1
            self.layer?.addSublayer(layer)
            marqueeLayer = layer
        }
        marqueeLayer?.path = CGPath(rect: rect, transform: nil)
        marqueeLayer?.isHidden = false
    }

    private func clearMarquee() {
        marqueeLayer?.isHidden = true
        marqueeLayer?.path = nil
    }

    private func indexPathsForItems(in rect: CGRect) -> Set<IndexPath> {
        var hits = Set<IndexPath>()
        for indexPath in indexPathsForVisibleItems() {
            guard let item = item(at: indexPath) as? IconCollectionItem else { continue }
            // Marquee must use icon/label rects, not the oversized layout cell.
            if item.interactiveFrames(in: self).contains(where: { $0.intersects(rect) }) {
                hits.insert(indexPath)
            }
        }
        return hits
    }
}

// MARK: - Item

protocol IconItemActionHandling: AnyObject {
    func open(entry: FileEntry)
    func requestRename(entry: FileEntry)
    func beginDrag(anchor: FileEntry) -> [URL]
    func endDrag()
    func commitRename()
    func cancelRename()
    func updateRenameDraft(_ text: String)
    func dropURLs(_ urls: [URL], onto entry: FileEntry, copy: Bool)
}

/// Programmatic collection item. `@objc` name is required so AppKit’s ObjC
/// `initWithNibName:bundle:` hits our override (otherwise it loads a missing nib
/// named after the reuse identifier and crashes).
@objc(ArborIconItem)
class IconCollectionItem: NSCollectionViewItem, NSTextFieldDelegate, NSDraggingSource {
    static let identifier = NSUserInterfaceItemIdentifier("arbor.iconItem")

    fileprivate let iconView = NSImageView()
    fileprivate let label = NSTextField(labelWithString: "")
    private let renameField = NSTextField(string: "")
    private let selectionBackground = NSView()
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?
    private var didBuildView = false
    private var iconMaxPoints: CGFloat = 64
    private var iconRequest: FileIcon.Request?

    private var entry: FileEntry?
    private var loadToken = UUID()
    private weak var actions: IconItemActionHandling?

    @objc
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        // Always nil — AppKit often passes the reuse id as the nib name.
        super.init(nibName: nil, bundle: nil)
        buildViewIfNeeded()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildViewIfNeeded()
    }

    override func loadView() {
        buildViewIfNeeded()
    }

    private func buildViewIfNeeded() {
        guard !didBuildView else { return }
        didBuildView = true

        let root = IconItemRootView()
        root.item = self
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root

        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 6
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        iconView.animates = false
        iconView.wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 3
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        renameField.isHidden = true
        renameField.alignment = .center
        renameField.delegate = self
        renameField.font = .systemFont(ofSize: 11)
        renameField.translatesAutoresizingMaskIntoConstraints = false
        renameField.target = self
        renameField.action = #selector(renameSubmitted)

        view.addSubview(selectionBackground)
        view.addSubview(iconView)
        view.addSubview(label)
        view.addSubview(renameField)

        let width = iconView.widthAnchor.constraint(equalToConstant: 64)
        let height = iconView.heightAnchor.constraint(equalToConstant: 64)
        iconWidthConstraint = width
        iconHeightConstraint = height

        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            // Finder-like: selection plate hugs the icon, not the whole grid cell.
            selectionBackground.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -4),
            selectionBackground.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            selectionBackground.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -4),
            selectionBackground.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),

            iconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            width,
            height,

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -4),

            renameField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            renameField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            renameField.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -8),
        ])
    }

    func configure(
        entry: FileEntry,
        metrics: IconViewMetrics,
        selected: Bool,
        renaming: Bool,
        renameDraft: String,
        actions: IconItemActionHandling
    ) {
        buildViewIfNeeded()
        self.entry = entry
        self.actions = actions

        let token = UUID()
        loadToken = token
        iconMaxPoints = metrics.iconPoints
        iconRequest?.cancel()

        iconView.alphaValue = CGFloat(entry.listingOpacity)
        label.alphaValue = CGFloat(entry.listingOpacity)
        label.stringValue = entry.name
        label.font = .systemFont(ofSize: metrics.labelFontSize)
        label.maximumNumberOfLines = metrics.lineLimit
        label.preferredMaxLayoutWidth = metrics.labelWidth
        label.invalidateIntrinsicContentSize()

        if let cached = FileIcon.cachedDisplay(for: entry.id, size: metrics.iconPoints) {
            applyDisplayedIcon(cached)
        } else {
            applyDisplayedIcon(
                FileIcon.Display(
                    image: NSImage(systemSymbolName: entry.symbolName, accessibilityDescription: nil)
                        ?? NSImage(),
                    isContentPreview: false
                )
            )
        }

        iconRequest = FileIcon.load(for: entry.id, size: metrics.iconPoints) { [weak self] display in
            guard let self, self.loadToken == token else { return }
            self.applyDisplayedIcon(display)
        }

        applySelectionChrome(selected: selected)
        setRenaming(renaming, draft: renameDraft)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconRequest?.cancel()
        iconRequest = nil
        loadToken = UUID()
        iconView.image = nil
    }

    private func applyDisplayedIcon(_ display: FileIcon.Display) {
        iconView.image = display.image
        iconView.layer?.cornerRadius = display.isContentPreview ? 3 : 0
        iconView.layer?.masksToBounds = display.isContentPreview
        let fitted = Self.aspectFit(display.image.size, max: iconMaxPoints)
        iconWidthConstraint?.constant = fitted.width
        iconHeightConstraint?.constant = fitted.height
    }

    private static func aspectFit(_ size: NSSize, max maxPoints: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else {
            return NSSize(width: maxPoints, height: maxPoints)
        }
        let scale = min(maxPoints / size.width, maxPoints / size.height)
        return NSSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }

    func setRenaming(_ active: Bool, draft: String) {
        renameField.isHidden = !active
        label.isHidden = active
        if active {
            renameField.stringValue = draft
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.view.window?.makeFirstResponder(self.renameField)
                self.renameField.currentEditor()?.selectAll(nil)
            }
        }
    }

    private func applySelectionChrome(selected: Bool) {
        if selected {
            // Subtle plate behind the icon only (Finder-like), accent chip on the name.
            selectionBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            label.drawsBackground = true
            label.backgroundColor = .controlAccentColor
            label.textColor = .white
            label.wantsLayer = true
            label.layer?.cornerRadius = 4
            label.layer?.masksToBounds = true
        } else {
            selectionBackground.layer?.backgroundColor = NSColor.clear.cgColor
            label.drawsBackground = false
            label.backgroundColor = .clear
            label.textColor = .labelColor
            label.layer?.cornerRadius = 0
        }
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = NSColor.clear.cgColor
            applySelectionChrome(selected: isSelected)
            if let entry {
                label.alphaValue = CGFloat(entry.listingOpacity)
                iconView.alphaValue = CGFloat(entry.listingOpacity)
            }
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @objc private func renameSubmitted() {
        actions?.updateRenameDraft(renameField.stringValue)
        actions?.commitRename()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !renameField.isHidden else { return }
        actions?.updateRenameDraft(renameField.stringValue)
        actions?.commitRename()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            actions?.cancelRename()
            return true
        }
        return false
    }

    func handleDoubleClick() {
        guard let entry else { return }
        actions?.open(entry: entry)
    }

    func handleNameClick() {
        guard let entry else { return }
        actions?.requestRename(entry: entry)
    }

    func beginFileDrag() {
        guard let entry, let actions, let event = NSApp.currentEvent else { return }
        let urls = actions.beginDrag(anchor: entry)
        let draggingItems = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(iconView.frame, contents: iconView.image)
            return item
        }
        view.beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        actions?.endDrag()
    }

    func labelContains(_ point: NSPoint) -> Bool {
        label.frame.insetBy(dx: -2, dy: -2).contains(point)
    }

    func iconContains(_ point: NSPoint) -> Bool {
        iconView.frame.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// Icon / label / rename field only — cell padding is “empty space” for marquee.
    func interactiveContains(_ point: NSPoint) -> Bool {
        if !renameField.isHidden, renameField.frame.insetBy(dx: -2, dy: -2).contains(point) {
            return true
        }
        return iconContains(point) || labelContains(point)
    }

    /// Icon + label frames in the collection view’s coordinate space (marquee hits).
    func interactiveFrames(in collectionView: NSView) -> [NSRect] {
        let icon = view.convert(iconView.frame.insetBy(dx: -2, dy: -2), to: collectionView)
        let name = view.convert(label.frame.insetBy(dx: -2, dy: -2), to: collectionView)
        return [icon, name]
    }
}

private final class IconItemRootView: NSView {
    weak var item: IconCollectionItem?
    private var downAt: NSPoint?
    private var moved = false
    private var lastClickAt: Date?

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Pass events through cell padding so the collection view can marquee / clear.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let item, !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        guard item.interactiveContains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        downAt = convert(event.locationInWindow, from: nil)
        moved = false
        superview?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt, let item else {
            superview?.mouseDragged(with: event)
            return
        }
        // Only start a file drag when the press began on icon/label.
        guard item.interactiveContains(downAt) else {
            superview?.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - downAt.x, point.y - downAt.y) > 4 {
            moved = true
            item.beginFileDrag()
            self.downAt = nil
            return
        }
        superview?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            downAt = nil
            superview?.mouseUp(with: event)
        }
        guard !moved, let item else { return }
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount >= 2 {
            item.handleDoubleClick()
            return
        }

        if item.isSelected,
           item.labelContains(point),
           let lastClickAt,
           Date().timeIntervalSince(lastClickAt) < 0.9
        {
            item.handleNameClick()
            self.lastClickAt = nil
            return
        }

        if item.iconContains(point) || item.labelContains(point) {
            lastClickAt = Date()
        }
    }
}
