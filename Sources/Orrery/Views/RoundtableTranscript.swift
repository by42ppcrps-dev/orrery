import SwiftUI
import AppKit

/// A native, width-constrained text layout breaks the recursive SwiftUI alignment chain seen
/// in the freeze sample. Streaming is coalesced and never measures the transcript's intrinsic
/// height. Selection/copy and the reader's scroll position survive incoming tokens.
struct RoundtableTranscript: NSViewRepresentable {
    let entries: [Roundtable.Entry]
    let live: [Provider: String]
    let thinking: Set<Provider>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = RoundtableScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.setAccessibilityLabel("Roundtable conversation")
        scroll.documentView = text
        context.coordinator.scroll = scroll
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.schedule(entries: entries, live: live, thinking: thinking)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.pending?.cancel()
    }

    @MainActor final class Coordinator {
        weak var scroll: NSScrollView?
        var pending: Task<Void, Never>?
        var latestEntries: [Roundtable.Entry] = []
        var latestLive: [Provider: String] = [:]
        var latestThinking: Set<Provider> = []
        private var renderedEntries: [Roundtable.Entry] = []
        private var renderedLive: [Provider: String] = [:]
        private var renderedThinking: Set<Provider> = []
        private var hasRendered = false
        private var completedText = NSAttributedString(string: "")

        func schedule(entries: [Roundtable.Entry], live: [Provider: String], thinking: Set<Provider>) {
            latestEntries = entries; latestLive = live; latestThinking = thinking
            guard pending == nil else { return }
            pending = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard let self else { return }
                self.pending = nil
                self.render()
            }
        }

        func render() {
            guard let scroll, let text = scroll.documentView as? NSTextView,
                  !hasRendered || latestEntries != renderedEntries || latestLive != renderedLive || latestThinking != renderedThinking else { return }
            let wasAtBottom = !hasRendered || scroll.documentVisibleRect.maxY >= text.bounds.height - 60
            let origin = scroll.contentView.bounds.origin
            let selection = text.selectedRange()
            if !hasRendered || latestEntries != renderedEntries {
                completedText = Self.formatted(entries: latestEntries, live: [:], thinking: [])
            }
            let output = NSMutableAttributedString(attributedString: latestEntries.isEmpty && !latestThinking.isEmpty ? NSAttributedString(string: "") : completedText)
            if !latestThinking.isEmpty { output.append(Self.formatted(entries: [], live: latestLive, thinking: latestThinking)) }
            text.textStorage?.setAttributedString(output)
            if selection.location <= output.length {
                text.setSelectedRange(NSRange(location: selection.location, length: min(selection.length, output.length - selection.location)))
            }
            if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
            if wasAtBottom { text.scrollRangeToVisible(NSRange(location: output.length, length: 0)) }
            else { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
            renderedEntries = latestEntries; renderedLive = latestLive; renderedThinking = latestThinking
            hasRendered = true
        }

        static func formatted(entries: [Roundtable.Entry], live: [Provider: String], thinking: Set<Provider>) -> NSAttributedString {
            let result = NSMutableAttributedString(string: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 12
            func append(_ text: String, font: NSFont, color: NSColor) {
                result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
            }
            func color(_ provider: Provider?) -> NSColor {
                switch provider { case .grok: return .systemOrange; case .claude: return .systemPurple; case .codex: return .systemGreen; case nil: return .controlAccentColor }
            }
            if entries.isEmpty && thinking.isEmpty {
                append("More minds. One conversation.\n", font: .systemFont(ofSize: 23, weight: .semibold), color: .labelColor)
                append("Compare ideas, investigate a problem, or let your agents build together. Choose Discuss or Work, then describe what you want below.", font: .systemFont(ofSize: 14), color: .secondaryLabelColor)
            }
            for entry in entries {
                let details = [entry.model, entry.effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                append(entry.displayName + (details.isEmpty ? "" : "  ·  " + details) + "\n", font: .systemFont(ofSize: 12, weight: .semibold), color: color(entry.provider))
                append(entry.text + "\n", font: .systemFont(ofSize: 14), color: entry.failed ? .systemRed : .labelColor)
                if let files = entry.editedFiles, !files.isEmpty {
                    append("Changed: " + files.joined(separator: ", ") + "\n", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
                }
                if let cost = entry.costUSD { append(String(format: "$%.4f\n", cost), font: .systemFont(ofSize: 11), color: .secondaryLabelColor) }
                append("\n", font: .systemFont(ofSize: 8), color: .labelColor)
            }
            for provider in Provider.allCases where thinking.contains(provider) {
                append(provider.displayName + " is answering…\n", font: .systemFont(ofSize: 12, weight: .semibold), color: color(provider))
                append((live[provider] ?? "") + "\n", font: .systemFont(ofSize: 14), color: .secondaryLabelColor)
            }
            return result
        }
    }
}

final class RoundtableScrollView: NSScrollView {
    private var followedBottom = false
    override func viewWillStartLiveResize() {
        followedBottom = documentVisibleRect.maxY >= (documentView?.bounds.height ?? 0) - 60
        super.viewWillStartLiveResize()
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if followedBottom, let text = documentView as? NSTextView {
            text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length, length: 0))
        }
    }
}
