import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Renders Markdown documents and source-code files in a dedicated preview
/// window: formatted Markdown, Mermaid diagrams, syntax-highlighted code,
/// zoom, and inline text editing.
///
/// Quick Look’s system panel shows these as plain text (macOS ships no
/// generators for them), so Arbor renders them itself. Everything else —
/// images, PDFs, media, `.txt` — keeps the system Quick Look.
///
/// View mode: Space/Esc close, ⌘E edits, ⌘+ ⌘− ⌘0 zoom, ⌘R reloads.
/// Edit mode: ⌘S saves, ⌘E (or Done) returns to the rendered view.
@MainActor
@Observable
final class DocumentPreviewController: NSObject, NSWindowDelegate {
    static let shared = DocumentPreviewController()

    enum Mode: Equatable {
        case view
        case edit
    }

    /// What the current file is rendered as.
    enum Kind: Equatable {
        case markdown
        case code(SourceLanguage)

        var isMarkdown: Bool {
            if case .markdown = self { return true }
            return false
        }
    }

    private(set) var documentURL: URL?
    private(set) var kind: Kind = .markdown
    /// 1.0 = 100%. Drives `WKWebView.pageZoom` so images scale with the text.
    private(set) var zoom: Double = 1.0
    private(set) var mode: Mode = .view
    /// Text shown in the editor. Baselines against `savedText` to detect edits.
    var draftText: String = ""
    private(set) var savedText: String = ""
    private(set) var saveError: String?

    static let minimumZoom: Double = 0.5
    static let maximumZoom: Double = 3.0
    private static let zoomStep: Double = 0.1

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var documentID = ""

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    var documentTitle: String {
        documentURL?.lastPathComponent ?? "Preview"
    }

    var isDirty: Bool {
        mode == .edit && draftText != savedText
    }

    // MARK: - What this viewer owns

    /// Files Arbor renders itself: Markdown and recognizable source code.
    /// `nil` means “leave it to system Quick Look”.
    nonisolated static func previewKind(for url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            return .markdown
        }
        if let language = SourceLanguage.detect(url: url) {
            return isProbablyText(url) ? .code(language) : nil
        }
        // Extension-less scripts: `#!/usr/bin/env python3`.
        guard isProbablyText(url), let firstLine = firstLine(of: url) else { return nil }
        if let language = SourceLanguage.detectFromShebang(firstLine) {
            return .code(language)
        }
        return nil
    }

    nonisolated static func isMarkdown(_ url: URL) -> Bool {
        previewKind(for: url)?.isMarkdown == true
    }

    /// NUL bytes mean binary; never hand those to the HTML view.
    nonisolated private static func isProbablyText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 8192)) ?? Data()
        return !sample.contains(0)
    }

    nonisolated private static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 1024)) ?? Data()
        guard let text = String(data: sample, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    private override init() {
        super.init()
        _ = makeWebView()
    }

    // MARK: - Presentation

    /// Space on a supported file: close if it is already showing, otherwise open.
    func toggle(_ url: URL) {
        if isVisible, documentURL == url, mode == .view {
            close()
        } else {
            guard confirmDiscardIfNeeded() else { return }
            show(url)
        }
    }

    func show(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let detected = Self.previewKind(for: url) else { return }
        guard confirmDiscardIfNeeded() else { return }

        documentURL = url
        kind = detected
        documentID = UUID().uuidString
        mode = .view
        saveError = nil

        let text = Self.loadText(at: url)
        savedText = text
        draftText = text
        render(text)

        let window = makeWindow()
        window.title = url.lastPathComponent
        window.subtitle = subtitle(for: url)
        window.isDocumentEdited = false
        window.makeKeyAndOrderFront(nil)
        installMonitor()
    }

    func close() {
        if let window, window.isVisible {
            window.performClose(nil)
        } else {
            teardown()
        }
    }

    // MARK: - Editing

    func beginEditing() {
        guard documentURL != nil else { return }
        saveError = nil
        if !isDirty {
            // Re-read so the editor never starts from a stale buffer.
            let text = documentURL.map(Self.loadText(at:)) ?? savedText
            savedText = text
            draftText = text
        }
        mode = .edit
        window?.isDocumentEdited = isDirty
    }

    /// Leaves edit mode, saving when there are changes.
    func commitEditing() {
        guard mode == .edit else { return }
        if isDirty {
            saveDraft()
            guard !isDirty else { return } // save failed; stay in the editor
        }
        mode = .view
    }

    func cancelEditing() {
        guard mode == .edit else { return }
        guard confirmDiscardIfNeeded() else { return }
        draftText = savedText
        window?.isDocumentEdited = false
        mode = .view
    }

    func toggleEditing() {
        switch mode {
        case .view: beginEditing()
        case .edit: commitEditing()
        }
    }

    @discardableResult
    func saveDraft() -> Bool {
        guard let url = documentURL else { return false }
        do {
            try draftText.write(to: url, atomically: true, encoding: .utf8)
            savedText = draftText
            saveError = nil
            window?.isDocumentEdited = false
            // Keep the rendered view in sync for when the user switches back.
            render(draftText)
            return true
        } catch {
            saveError = error.localizedDescription
            window?.isDocumentEdited = true
            return false
        }
    }

    /// Re-read the file from disk, keeping zoom. Drops unsaved edits after confirming.
    func reload() {
        guard let url = documentURL, confirmDiscardIfNeeded() else { return }
        let text = Self.loadText(at: url)
        savedText = text
        draftText = text
        render(text)
        window?.isDocumentEdited = false
    }

    // MARK: - Rendering

    private func render(_ text: String) {
        guard let url = documentURL else { return }

        let html: String
        switch kind {
        case .markdown:
            html = MarkdownHTMLRenderer.html(
                markdown: text,
                title: url.lastPathComponent,
                context: MarkdownHTMLRenderer.Context(documentURL: url, docID: documentID)
            )
        case .code(let language):
            html = CodeHTMLRenderer.html(
                code: text,
                language: language,
                fileName: url.lastPathComponent,
                lineCount: text.isEmpty ? 0 : text.components(separatedBy: "\n").count
            )
        }

        makeWebView().loadHTMLString(
            html,
            baseURL: URL(string: "\(MarkdownHTMLRenderer.assetScheme)://\(documentID)/")
        )
    }

    private func subtitle(for url: URL) -> String {
        let path = url.deletingLastPathComponent().path
        if case .code(let language) = kind {
            return "\(language.displayName) · \(path)"
        }
        return path
    }

    private static func loadText(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            ?? ""
    }

    // MARK: - Zoom

    func zoomIn() {
        setZoom(zoom + Self.zoomStep)
    }

    func zoomOut() {
        setZoom(zoom - Self.zoomStep)
    }

    func resetZoom() {
        setZoom(1.0)
    }

    func setZoom(_ value: Double) {
        let clamped = min(max(value, Self.minimumZoom), Self.maximumZoom)
        // Snap to 1/10 so repeated steps don’t drift into 99% / 101%.
        zoom = (clamped * 10).rounded() / 10
        webView?.pageZoom = CGFloat(zoom)
    }

    // MARK: - Views

    private func makeWebView() -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        let handler = DocumentAssetSchemeHandler()
        handler.controller = self
        configuration.setURLSchemeHandler(handler, forURLScheme: MarkdownHTMLRenderer.assetScheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.pageZoom = CGFloat(zoom)
        self.webView = webView
        return webView
    }

    private func makeWindow() -> NSWindow {
        if let window { return window }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 420, height: 320)
        window.setFrameAutosaveName("Arbor.DocumentPreview")
        window.center()
        window.contentView = NSHostingView(rootView: DocumentPreviewContent(controller: self))

        self.window = window
        return window
    }

    // MARK: - Key handling

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if flags.contains(.command) {
                switch key {
                case "e":
                    self.toggleEditing()
                    return nil
                case "s":
                    self.saveDraft()
                    return nil
                case "r":
                    self.reload()
                    return nil
                case "+", "=":
                    guard self.mode == .view else { return event }
                    self.zoomIn()
                    return nil
                case "-":
                    guard self.mode == .view else { return event }
                    self.zoomOut()
                    return nil
                case "0":
                    guard self.mode == .view else { return event }
                    self.resetZoom()
                    return nil
                default:
                    return event
                }
            }
            guard flags.isEmpty else { return event }

            // In the editor, Space/Esc belong to the text view.
            guard self.mode == .view else {
                if event.keyCode == 53 { self.cancelEditing() }
                return event
            }

            switch event.keyCode {
            case 49, 53: // space, escape
                self.close()
                return nil
            default:
                return event
            }
        }
    }

    private func teardown() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        documentURL = nil
        documentID = ""
        mode = .view
        draftText = ""
        savedText = ""
        saveError = nil
    }

    // MARK: - Unsaved changes

    /// `true` when it is safe to replace the document (no pending edits or the
    /// user chose to discard them).
    private func confirmDiscardIfNeeded() -> Bool {
        guard isDirty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes to “\(documentTitle)”?"
        alert.informativeText = "Your edits will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDraft()
        case .alertSecondButtonReturn:
            return false
        default:
            draftText = savedText
            window?.isDocumentEdited = false
            return true
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmDiscardIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
    }
}

// MARK: - Navigation

extension DocumentPreviewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // The initial load and in-page anchors are ours; anything the user
        // clicks opens outside so the preview never becomes a browser.
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url
        else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == MarkdownHTMLRenderer.assetScheme {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "file" || url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}

// MARK: - Local asset scheme

/// Serves the bundled Mermaid/highlight.js runtimes and images referenced by
/// the document. Only image files are exposed from the filesystem, so the web
/// view cannot read arbitrary documents.
nonisolated final class DocumentAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var controller: DocumentPreviewController?

    static let vendorHost = "vendor"
    private static var vendorCache: [String: Data] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        // WebKit calls scheme handlers on the main thread.
        MainActor.assumeIsolated {
            serve(urlSchemeTask)
        }
    }

    @MainActor
    private func serve(_ urlSchemeTask: WKURLSchemeTask) {
        let fail: (Error) -> Void = { error in
            urlSchemeTask.didFailWithError(error)
        }

        guard let url = urlSchemeTask.request.url else {
            fail(DocumentAssetError.noDocument)
            return
        }

        // Bundled vendor assets (Mermaid, highlight.js), served from the app bundle.
        if url.host == Self.vendorHost {
            serveVendorAsset(url, task: urlSchemeTask, fail: fail)
            return
        }

        let absolutePath = url.path
        guard absolutePath.hasPrefix("/"), absolutePath.count > 1 else {
            fail(DocumentAssetError.notFound(url.absoluteString))
            return
        }

        let candidate = URL(fileURLWithPath: absolutePath).standardizedFileURL
        let type = UTType(filenameExtension: candidate.pathExtension)
        guard let mime = type?.preferredMIMEType,
              type?.conforms(to: .image) == true || candidate.pathExtension.lowercased() == "svg"
        else {
            fail(DocumentAssetError.notAnImage(candidate.path))
            return
        }

        guard let data = try? Data(contentsOf: candidate), !data.isEmpty else {
            fail(DocumentAssetError.notFound(candidate.path))
            return
        }

        respond(task: urlSchemeTask, data: data, mime: mime, url: url)
    }

    @MainActor
    private func serveVendorAsset(_ url: URL, task: WKURLSchemeTask, fail: (Error) -> Void) {
        let fileName = (url.path as NSString).lastPathComponent
        if let cached = Self.vendorCache[fileName] {
            respond(task: task, data: cached, mime: Self.mimeType(for: fileName), url: url)
            return
        }

        let nsName = fileName as NSString
        let name = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: ext),
            Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "vendor"),
            Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources/vendor"),
        ]
        guard let resource = candidates.compactMap({ $0 }).first,
              let data = try? Data(contentsOf: resource)
        else {
            fail(DocumentAssetError.notFound(fileName))
            return
        }
        Self.vendorCache[fileName] = data
        respond(task: task, data: data, mime: Self.mimeType(for: fileName), url: url)
    }

    private static func mimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    @MainActor
    private func respond(task: WKURLSchemeTask, data: Data, mime: String, url: URL) {
        let response = URLResponse(
            url: url,
            mimeType: mime,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchronous serving: nothing to cancel.
    }
}

enum DocumentAssetError: LocalizedError {
    case noDocument
    case notFound(String)
    case notAnImage(String)

    var errorDescription: String? {
        switch self {
        case .noDocument: return "No document is open."
        case .notFound(let path): return "Asset not found: \(path)"
        case .notAnImage(let path): return "Only images can be previewed: \(path)"
        }
    }
}

// MARK: - SwiftUI content

struct DocumentPreviewContent: View {
    @Bindable var controller: DocumentPreviewController

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch controller.mode {
            case .view:
                DocumentWebView(controller: controller)
            case .edit:
                DocumentEditor(controller: controller)
            }

            controls
                .padding(14)
        }
        .frame(minWidth: 320, minHeight: 240)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            if controller.mode == .view {
                Button {
                    controller.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload (⌘R)")

                Divider().frame(height: 14).padding(.horizontal, 2)
            }

            Button {
                controller.toggleEditing()
            } label: {
                Label(
                    controller.mode == .edit ? "Done" : "Edit",
                    systemImage: controller.mode == .edit ? "checkmark" : "pencil"
                )
                .labelStyle(.titleAndIcon)
            }
            .help(controller.mode == .edit ? "Save and view (⌘E)" : "Edit as text (⌘E)")

            if controller.mode == .edit, controller.isDirty {
                Button {
                    controller.saveDraft()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save (⌘S)")
            }

            if controller.mode == .view {
                Divider().frame(height: 14).padding(.horizontal, 2)

                Button {
                    controller.zoomOut()
                } label: {
                    Image(systemName: "minus")
                }
                .help("Zoom out (⌘−)")
                .disabled(controller.zoom <= DocumentPreviewController.minimumZoom)

                Button {
                    controller.resetZoom()
                } label: {
                    Text("\(Int((controller.zoom * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(minWidth: 42)
                }
                .help("Actual size (⌘0)")

                Button {
                    controller.zoomIn()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Zoom in (⌘+)")
                .disabled(controller.zoom >= DocumentPreviewController.maximumZoom)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        .accessibilityLabel("Document preview controls")
    }
}

/// Text editor for ⌘E. Monospaced, with a status strip for save errors.
private struct DocumentEditor: View {
    @Bindable var controller: DocumentPreviewController
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $controller.draftText)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear {
                    // TextEditor does not take focus by itself; typing would
                    // otherwise land nowhere until the user clicks in.
                    DispatchQueue.main.async { editorFocused = true }
                }

            HStack(spacing: 8) {
                if let error = controller.saveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if controller.isDirty {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.orange, .clear)
                } else {
                    Text(controller.kind.isMarkdown
                         ? "Markdown source"
                         : "Source code · ⌘S saves")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(controller.documentURL?.path ?? "")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// Hosts the single controller-owned `WKWebView`.
private struct DocumentWebView: NSViewRepresentable {
    let controller: DocumentPreviewController

    func makeNSView(context: Context) -> NSView {
        controller.webViewForDisplay
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension DocumentPreviewController {
    /// The controller owns the web view so zoom and loads survive SwiftUI updates.
    var webViewForDisplay: NSView {
        makeWebView()
    }
}
