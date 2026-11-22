import AppKit
import SwiftUI

/// Represents a parsed block of note content for interleaved text + inline images.
enum NoteContentBlock: Identifiable, Equatable {
    case text(id: String, value: String)
    case image(id: String, sha256: String, localPath: String)

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .image(let id, _, _): return id
        }
    }
}

/// Parses markdown content containing `![...](whim://blob/<sha256>)` tokens into
/// interleaved text and inline image blocks so every pasted image stays in its exact position.
enum NoteContentParser {
    private static let regex = try! NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(whim://blob/([a-fA-F0-9]{64})\)"#,
        options: []
    )

    static func parse(content: String, attachments: [WhimAttachment]?) -> [NoteContentBlock] {
        var pathByHash: [String: String] = [:]
        for att in attachments ?? [] {
            if let p = att.localPath, !p.isEmpty {
                pathByHash[att.sha256] = p
            }
        }

        let ns = content as NSString
        let matches = regex.matches(in: content, options: [], range: NSRange(location: 0, length: ns.length))
        var blocks: [NoteContentBlock] = []
        var referenced = Set<String>()
        var cursor = 0
        var idx = 0

        for m in matches {
            if m.range.location > cursor {
                let slice = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !slice.isEmpty {
                    blocks.append(.text(id: "t-\(idx)", value: slice))
                    idx += 1
                }
            }
            let hash = ns.substring(with: m.range(at: 1))
            referenced.insert(hash)
            if let path = pathByHash[hash] ?? resolveLocalBlobPath(sha256: hash) {
                blocks.append(.image(id: "i-\(idx)-\(hash.prefix(8))", sha256: hash, localPath: path))
                idx += 1
            }
            cursor = m.range.location + m.range.length
        }

        if cursor < ns.length {
            let tail = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                blocks.append(.text(id: "t-\(idx)", value: tail))
                idx += 1
            }
        }

        // Legacy fallback: append any attachment not referenced inline in content
        for att in attachments ?? [] {
            if !referenced.contains(att.sha256), let path = att.localPath, !path.isEmpty {
                blocks.append(.image(id: "leg-\(att.sha256.prefix(8))", sha256: att.sha256, localPath: path))
            }
        }
        return blocks
    }

    static func resolveLocalBlobPath(sha256: String) -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let blobsDir = appSupport.appendingPathComponent("Whim/blobs", isDirectory: true)
        for ext in ["png", "jpg", "jpeg", "webp", "gif", "heic"] {
            let candidate = blobsDir.appendingPathComponent("\(sha256).\(ext)").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Custom NSTextAttachment carrying the blob SHA-256 so serialization turns it back into
/// `![image](whim://blob/<sha256>)` at the exact cursor position in the document.
final class WhimImageAttachment: NSTextAttachment {
    let sha256: String
    let mime: String
    let sizeBytes: Int64
    let localPath: String

    init(sha256: String, mime: String, sizeBytes: Int64, localPath: String, image: NSImage) {
        self.sha256 = sha256
        self.mime = mime
        self.sizeBytes = sizeBytes
        self.localPath = localPath
        super.init(data: nil, ofType: nil)

        // Scale thumbnail nicely for inline editing while keeping crisp aspect ratio
        let maxW: CGFloat = 240
        let maxH: CGFloat = 150
        let orig = image.size
        var drawW = max(40, orig.width)
        var drawH = max(40, orig.height)
        let ratio = min(maxW / drawW, maxH / drawH, 1.0)
        drawW *= ratio
        drawH *= ratio

        let thumb = NSImage(size: NSSize(width: drawW, height: drawH))
        thumb.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: drawW, height: drawH)
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).addClip()
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
        thumb.unlockFocus()

        self.image = thumb
        self.bounds = CGRect(x: 0, y: -4, width: drawW, height: drawH)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }
}

/// Native NSTextView subclass that intercepts Cmd+V image paste and inserts the image
/// directly at the current caret position (inline inside the document, NOT pooled at bottom).
final class WhimNSTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onInsertBlob: ((WhimAttachment) -> Void)?
    var onContentChanged: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChanged?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChanged?(false) }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        // Cmd+Return submits note
        if event.modifierFlags.contains(.command) && (event.keyCode == 36 || event.keyCode == 76) {
            onCommandReturn?()
            return
        }
        // Escape closes floating window
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if tryPasteClipboardImage() {
            return
        }
        super.pasteAsPlainText(sender)
    }

    @discardableResult
    func tryPasteClipboardImage() -> Bool {
        let pb = NSPasteboard.general
        var pngData: Data? = pb.data(forType: .png)
        if pngData == nil, let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            pngData = rep.representation(using: .png, properties: [:])
        }
        if pngData == nil,
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first,
           ["png", "jpg", "jpeg", "webp", "gif", "heic"].contains(first.pathExtension.lowercased()),
           let raw = try? Data(contentsOf: first),
           let img = NSImage(data: raw),
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            pngData = rep.representation(using: .png, properties: [:])
        }
        guard let data = pngData, let img = NSImage(data: data) else {
            return false
        }
        guard let saved = try? CoreBridge.shared.saveBlob(data: data, mime: "image/png") else {
            return false
        }
        insertInlineImage(
            sha256: saved.sha256,
            mime: saved.mime,
            sizeBytes: saved.sizeBytes,
            localPath: saved.localPath,
            image: img
        )
        let att = WhimAttachment(
            sha256: saved.sha256,
            mime: saved.mime,
            sizeBytes: saved.sizeBytes,
            localPath: saved.localPath
        )
        onInsertBlob?(att)
        onContentChanged?()
        return true
    }

    func insertInlineImage(sha256: String, mime: String, sizeBytes: Int64, localPath: String, image: NSImage) {
        let attachment = WhimImageAttachment(sha256: sha256, mime: mime, sizeBytes: sizeBytes, localPath: localPath, image: image)
        let attr = NSMutableAttributedString()
        let sel = selectedRange()
        let str = string as NSString
        if sel.location > 0 && str.character(at: sel.location - 1) != 10 {
            attr.append(NSAttributedString(string: "\n", attributes: defaultTypingAttrs()))
        }
        attr.append(NSAttributedString(attachment: attachment))
        attr.append(NSAttributedString(string: "\n", attributes: defaultTypingAttrs()))
        textStorage?.replaceCharacters(in: sel, with: attr)
        let newLoc = sel.location + attr.length
        setSelectedRange(NSRange(location: newLoc, length: 0))
        typingAttributes = defaultTypingAttrs()
    }

    func insertPlainTextAtCursor(_ snippet: String) {
        let sel = selectedRange()
        let attr = NSAttributedString(string: snippet, attributes: defaultTypingAttrs())
        textStorage?.replaceCharacters(in: sel, with: attr)
        setSelectedRange(NSRange(location: sel.location + attr.length, length: 0))
        typingAttributes = defaultTypingAttrs()
        onContentChanged?()
    }

    /// Serializes the rich attributed text (including inline image attachments) back to
    /// portable markdown with `![image](whim://blob/<sha256>)` in exact document order.
    func serializeMarkdown() -> (String, [WhimAttachment]) {
        guard let storage = textStorage else { return ("", []) }
        var out = ""
        var atts: [WhimAttachment] = []
        var seen = Set<String>()
        let full = NSRange(location: 0, length: storage.length)

        storage.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            if let att = attrs[.attachment] as? WhimImageAttachment {
                out += "![image](whim://blob/\(att.sha256))"
                if !seen.contains(att.sha256) {
                    seen.insert(att.sha256)
                    atts.append(WhimAttachment(
                        sha256: att.sha256,
                        mime: att.mime,
                        sizeBytes: att.sizeBytes,
                        localPath: att.localPath
                    ))
                }
            } else {
                out += (storage.string as NSString).substring(with: range)
            }
        }
        return (out, atts)
    }

    /// Loads markdown containing `![image](whim://blob/<sha256>)` into inline editable form.
    func loadMarkdown(_ markdown: String, attachments: [WhimAttachment]? = nil) {
        let result = NSMutableAttributedString()
        let blocks = NoteContentParser.parse(content: markdown, attachments: attachments)
        for (idx, block) in blocks.enumerated() {
            if idx > 0 {
                result.append(NSAttributedString(string: "\n", attributes: defaultTypingAttrs()))
            }
            switch block {
            case .text(_, let val):
                result.append(NSAttributedString(string: val, attributes: defaultTypingAttrs()))
            case .image(_, let sha, let path):
                if let img = NSImage(contentsOfFile: path) {
                    let att = WhimImageAttachment(sha256: sha, mime: "image/png", sizeBytes: 0, localPath: path, image: img)
                    result.append(NSAttributedString(attachment: att))
                }
            }
        }
        textStorage?.setAttributedString(result)
        typingAttributes = defaultTypingAttrs()
        setSelectedRange(NSRange(location: result.length, length: 0))
    }

    func defaultTypingAttrs() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4.5
        return [
            .font: NSFont.systemFont(ofSize: 14.5),
            .foregroundColor: NSColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1.0),
            .paragraphStyle: style
        ]
    }
}

/// Controller allowing SwiftUI toolbar buttons to insert tags, paste images, or clear the NSTextView.
final class InlineEditorController: ObservableObject {
    weak var textView: WhimNSTextView?

    func pasteImage() { _ = textView?.tryPasteClipboardImage() }
    func insertSnippet(_ s: String) { textView?.insertPlainTextAtCursor(s) }
    func clear() {
        textView?.textStorage?.setAttributedString(NSAttributedString(string: ""))
        textView?.onContentChanged?()
    }
    func load(markdown: String, attachments: [WhimAttachment]?) {
        textView?.loadMarkdown(markdown, attachments: attachments)
        textView?.onContentChanged?()
    }
    func serialize() -> (String, [WhimAttachment]) {
        textView?.serializeMarkdown() ?? ("", [])
    }
    func focus() {
        textView?.window?.makeFirstResponder(textView)
    }
    func replaceActiveTag(with fullTag: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let prefix = (storage.string as NSString).substring(to: sel.location)
        if let hashRange = prefix.range(of: "#", options: .backwards) {
            let startIdx = prefix.distance(from: prefix.startIndex, to: hashRange.lowerBound)
            let replaceRange = NSRange(location: startIdx, length: sel.location - startIdx)
            let attr = NSAttributedString(string: "#\(fullTag) ", attributes: tv.defaultTypingAttrs())
            storage.replaceCharacters(in: replaceRange, with: attr)
            tv.setSelectedRange(NSRange(location: startIdx + attr.length, length: 0))
            tv.onContentChanged?()
        }
    }
}

/// SwiftUI wrapper around WhimNSTextView for true inline Cmd+V image editing.
struct InlineRichEditor: NSViewRepresentable {
    let controller: InlineEditorController
    var initialMarkdown: String = ""
    var initialAttachments: [WhimAttachment]? = nil
    var autoFocus: Bool = false
    var onTextChange: (String, [WhimAttachment]) -> Void
    var onFocusChange: (Bool) -> Void
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = WhimNSTextView(frame: .zero)
        tv.drawsBackground = false
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.insertionPointColor = NSColor(red: 0.306, green: 0.490, blue: 0.369, alpha: 1.0)
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.typingAttributes = tv.defaultTypingAttrs()
        tv.delegate = context.coordinator

        tv.onCommandReturn = onSubmit
        tv.onEscape = onEscape
        tv.onFocusChanged = onFocusChange
        tv.onContentChanged = { [weak tv] in
            guard let tv else { return }
            let (md, atts) = tv.serializeMarkdown()
            onTextChange(md, atts)
        }

        if !initialMarkdown.isEmpty {
            tv.loadMarkdown(initialMarkdown, attachments: initialAttachments)
        }

        controller.textView = tv
        scroll.documentView = tv

        if autoFocus {
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
            }
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let tv = nsView.documentView as? WhimNSTextView {
            controller.textView = tv
            tv.onCommandReturn = onSubmit
            tv.onEscape = onEscape
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: InlineRichEditor
        init(parent: InlineRichEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? WhimNSTextView else { return }
            let (md, atts) = tv.serializeMarkdown()
            parent.onTextChange(md, atts)
        }
    }
}
