import SwiftUI
import AppKit

/// A one-shot instruction from the rest of the app to the editor (jump to a diagnostic, focus
/// the caret). Consumed and cleared, so the same request never fires twice.
enum EditorRequest: Equatable {
    case goToLine(Int)
    case select(NSRange)
    case focus
}

/// SwiftUI wrapper around `CodeTextView`. Switching tabs swaps the text storage under the same
/// layout manager rather than rebuilding the view, so scroll position and undo history survive.
struct CodeEditorView: NSViewRepresentable {
    let document: CodeDocument
    var wrapsLines: Bool
    @Binding var request: EditorRequest?
    var onSave: () -> Void
    var onEdit: () -> Void
    var model: AppModel? = nil
    var pendingCompletions: [LSPCompletionItem]? = nil
    var pendingHover: String? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onSave: onSave, onEdit: onEdit, model: model)
    }

    /// The AppKit stack, built in one place so `--audit` renders exactly what the window does.
    struct Stack {
        let scrollView: NSScrollView
        let textView: CodeTextView
        let ruler: LineNumberRuler
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
    }

    @MainActor
    static func makeStack(for document: CodeDocument) -> Stack {
        let layoutManager = NSLayoutManager()
        let hugeSize = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: 0, height: hugeSize))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        document.storage.addLayoutManager(layoutManager)

        // A non-zero starting frame matters: with `isHorizontallyResizable` the text view sizes
        // itself to its content, and one that starts at zero never grows — the gutter then draws
        // line numbers beside an apparently empty page.
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                    textContainer: container)
        textView.configure()
        textView.decorator = document.decorator
        textView.language = document.language
        textView.isEditable = document.isReadable
        textView.typingAttributes = document.decorator.baseAttributes
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: hugeSize, height: hugeSize)
        textView.isVerticallyResizable = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background

        let ruler = LineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        return Stack(scrollView: scrollView, textView: textView, ruler: ruler,
                     layoutManager: layoutManager, container: container)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let stack = Self.makeStack(for: document)
        let scrollView = stack.scrollView
        let textView = stack.textView
        let ruler = stack.ruler
        let layoutManager = stack.layoutManager
        textView.delegate = context.coordinator
        textView.onSaveRequested = onSave
        context.coordinator.attachLSP(to: textView)

        context.coordinator.textView = textView
        context.coordinator.layoutManager = layoutManager
        context.coordinator.ruler = ruler
        context.coordinator.document = document
        context.coordinator.attach(document)
        context.coordinator.applyWrapping(wrapsLines)

        // Redraw the gutter while scrolling, or the numbers lag the text.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { _ in
                MainActor.assumeIsolated {
                    ruler.needsDisplay = true
                    textView.dismissHover()
                }
            })
        // ⌘+ / ⌘- change the theme's font, which every open document has to pick up.
        context.coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: .editorFontChanged, object: nil, queue: .main) { [weak textView] _ in
                MainActor.assumeIsolated {
                    guard let textView else { return }
                    textView.font = EditorTheme.font
                    textView.decorator?.rehighlightAll()
                    textView.typingAttributes = textView.decorator?.baseAttributes ?? [:]
                    ruler.resizeToFit(
                        lineCount: textView.decorator?.lineStartOffsets.count ?? 1)
                    ruler.needsDisplay = true
                }
            })
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSave = onSave
        coordinator.onEdit = onEdit
        coordinator.model = model
        coordinator.textView?.onSaveRequested = onSave
        if let textView = coordinator.textView {
            coordinator.attachLSP(to: textView)
            if let items = pendingCompletions {
                model?.pendingLSPCompletions = nil
                textView.presentCompletions(items)
            }
            if let hover = pendingHover {
                model?.pendingLSPHover = nil
                textView.presentHover(hover)
            }
        }

        if coordinator.document !== document {
            coordinator.switchTo(document)
        }
        coordinator.applyWrapping(wrapsLines)
        coordinator.retileIfNeeded()
        coordinator.textView?.isEditable = document.isReadable
        coordinator.textView?.language = document.language

        if let pending = request {
            coordinator.perform(pending)
            DispatchQueue.main.async { request = nil }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var textView: CodeTextView?
        var layoutManager: NSLayoutManager?
        var ruler: LineNumberRuler?
        var document: CodeDocument?
        var onSave: () -> Void
        var onEdit: () -> Void
        var model: AppModel?
        var observers: [NSObjectProtocol] = []
        /// nil until the first call, so the initial layout is always applied.
        private var appliedWrapping: Bool?
        private var suppressEdits = false

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        init(onSave: @escaping () -> Void, onEdit: @escaping () -> Void, model: AppModel? = nil) {
            self.onSave = onSave
            self.onEdit = onEdit
            self.model = model
        }

        func attachLSP(to textView: CodeTextView) {
            textView.onEditWithAgent = { [weak self] range, text in
                guard let self, let document = self.document, let model = self.model else { return }
                model.beginInlineEdit(document: document, range: range, selection: text, textView: self.textView)
            }
            textView.onRequestHover = { [weak self] line, column, token in
                guard let self, let document = self.document, let model = self.model else { return }
                Task { @MainActor in
                    let result = await model.lsp.hover(for: document, line: line, column: column)
                    guard self.textView?.hoverToken == token else { return }
                    if let text = result.value, !text.isEmpty {
                        self.textView?.receiveHover(text, token: token)
                    } else if result.outcome != .success, let note = result.note {
                        model.editorNote = note
                    }
                }
            }
            textView.onRequestDefinition = { [weak self] line, column in
                guard let self, let document = self.document, let model = self.model else { return }
                Task { @MainActor in
                    await model.jumpToDefinition(in: document, line: line, column: column)
                }
            }
            textView.onRequestCompletions = { [weak self] line, column, token in
                guard let self, let document = self.document, let model = self.model else { return }
                Task { @MainActor in
                    let result = await model.lsp.completions(for: document, line: line, column: column)
                    guard self.textView?.completionToken == token else { return }
                    if result.outcome == .success {
                        self.textView?.receiveCompletions(result.value, token: token)
                    } else {
                        self.textView?.dismissCompletions()
                        if let note = result.note { model.editorNote = note }
                    }
                }
            }
        }

        func attach(_ document: CodeDocument) {
            self.document = document
            document.decorator.onRehighlight = { [weak self] in self?.refreshRuler() }
            refreshRuler()
            textView?.setSelectedRange(clamp(document.selection))
        }

        func detach() {
            document?.decorator.onRehighlight = nil
            if let layoutManager { document?.storage.removeLayoutManager(layoutManager) }
        }

        func switchTo(_ next: CodeDocument) {
            guard let layoutManager, let textView else { return }
            // Remember where we were in the outgoing document.
            document?.selection = textView.selectedRange()
            document?.decorator.onRehighlight = nil
            document?.storage.removeLayoutManager(layoutManager)

            suppressEdits = true
            next.storage.addLayoutManager(layoutManager)
            textView.decorator = next.decorator
            textView.language = next.language
            textView.typingAttributes = next.decorator.baseAttributes
            textView.isEditable = next.isReadable
            suppressEdits = false

            attach(next)
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        /// The two AppKit recipes are not symmetric, and mixing them is what produces a text
        /// view that lays out glyphs but never draws them.
        ///
        ///   wrapping — the container follows the view's width and the view follows the scroll
        ///              view's, so `autoresizingMask` must contain `.width`.
        ///   no wrap  — the view sizes itself to the widest line, so `autoresizingMask` must be
        ///              empty or the scroll view keeps resetting its width.
        func applyWrapping(_ wraps: Bool) {
            guard let textView, let container = textView.textContainer,
                  let scrollView = textView.enclosingScrollView else { return }
            guard wraps != appliedWrapping else { return }
            appliedWrapping = wraps
            let huge = CGFloat.greatestFiniteMagnitude
            if wraps {
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [NSView.AutoresizingMask.width]
                container.widthTracksTextView = true
                container.containerSize = NSSize(width: scrollView.contentSize.width,
                                                 height: huge)
                textView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width,
                                        height: max(textView.frame.height, 1))
                scrollView.hasHorizontalScroller = false
            } else {
                textView.isHorizontallyResizable = true
                textView.autoresizingMask = []
                container.widthTracksTextView = false
                container.containerSize = NSSize(width: huge, height: huge)
                scrollView.hasHorizontalScroller = true
            }
            textView.sizeToFit()
            textView.needsDisplay = true
        }

        /// Re-assert the gutter's reserved space once SwiftUI has given the view a real size.
        func retileIfNeeded() { ruler?.reserveSpace() }

        func perform(_ request: EditorRequest) {
            guard let textView else { return }
            switch request {
            case let .goToLine(line): textView.goToLine(line)
            case let .select(range): textView.select(range)
            case .focus: textView.window?.makeFirstResponder(textView)
            }
        }

        private func clamp(_ range: NSRange) -> NSRange {
            let length = (textView?.string as NSString?)?.length ?? 0
            let location = min(max(0, range.location), length)
            return NSRange(location: location, length: min(range.length, length - location))
        }

        func refreshRuler() {
            guard let ruler, let document else { return }
            ruler.severities = document.decorator.severityByLine()
            ruler.resizeToFit(lineCount: document.decorator.lineStartOffsets.count)
            ruler.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressEdits, let document, let textView else { return }
            document.isDirty = true
            document.selection = textView.selectedRange()
            refreshRuler()
            onEdit()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !suppressEdits, let textView else { return }
            document?.selection = textView.selectedRange()
        }
    }
}
