import SwiftUI

private final class MarkdownBlockBox: NSObject {
    let chunks: [MarkdownChunk]
    init(_ chunks: [MarkdownChunk]) { self.chunks = chunks }
}

enum MarkdownChunk: Identifiable, Equatable {
    case richText(id: Int, attributed: AttributedString)
    case codeBlock(id: Int, lang: String, code: String)

    var id: Int {
        switch self {
        case .richText(let id, _): return id
        case .codeBlock(let id, _, _): return id
        }
    }
}

private enum MarkdownRenderCache {
    private static let chunkCache: NSCache<NSString, MarkdownBlockBox> = {
        let c = NSCache<NSString, MarkdownBlockBox>()
        c.countLimit = 600
        return c
    }()

    private static let parseOpts = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    private static let inlineTagRegex = try! NSRegularExpression(
        pattern: #"(^|[\s(\[{（【「『，。、；：！？,.;:!?])(#([^\s#,.;:!?，。、；：！？)\]}）】」』]+))"#,
        options: [.anchorsMatchLines]
    )

    static func chunks(for text: String, scheme: ColorScheme, highlightQuery: String, taskOffset: Int) -> [MarkdownChunk] {
        let isDark = scheme == .dark
        let trimmedQ = highlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(isDark ? "d" : "l")|\(taskOffset)|\(trimmedQ)|\(text)" as NSString
        if let hit = chunkCache.object(forKey: key) {
            return hit.chunks
        }
        let parsed = buildChunks(text: text, scheme: scheme, highlightQuery: trimmedQ, taskOffset: taskOffset)
        chunkCache.setObject(MarkdownBlockBox(parsed), forKey: key)
        return parsed
    }

    private static func indentLevel(of line: String) -> Int {
        var spaces = 0
        for ch in line {
            if ch == " " {
                spaces += 1
            } else if ch == "\t" {
                spaces += 2
            } else {
                break
            }
        }
        return min(spaces / 2, 6)
    }

    private static func bulletSymbol(for level: Int) -> String {
        switch level % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }

    private static func parseOrderedList(_ s: String) -> (String, String)? {
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let prefix = s[..<dot]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return nil }
        let afterDot = s.index(after: dot)
        guard afterDot < s.endIndex, s[afterDot] == " " else { return nil }
        let body = String(s[s.index(after: afterDot)...])
        return (String(prefix), body)
    }

    private static func applyInlineTags(to attr: inout AttributedString, scheme: ColorScheme) {
        let plain = String(attr.characters)
        guard plain.contains("#") else { return }
        let ns = plain as NSString
        let matches = inlineTagRegex.matches(in: plain, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }

        let tagFg = FlomoPalette.tagText(scheme)
        let tagBg = FlomoPalette.tagBg(scheme)

        for m in matches {
            let tokenNSRange = m.range(at: 2)
            let rawTag = ns.substring(with: m.range(at: 3))
            let normalized = rawTag
                .split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "/")
            guard !normalized.isEmpty,
                  let swiftRange = Range(tokenNSRange, in: plain),
                  let attrRange = Range(swiftRange, in: attr) else { continue }
            attr[attrRange].foregroundColor = tagFg
            attr[attrRange].backgroundColor = tagBg
            if let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "whim-tag://tag/\(encoded)") {
                attr[attrRange].link = url
            }
        }
    }

    private static func applySearchHighlight(to attr: inout AttributedString, query: String, scheme: ColorScheme) {
        guard !query.isEmpty else { return }
        let plain = String(attr.characters)
        var searchStart = plain.startIndex
        let bg = scheme == .dark ? Color(hex: 0xF59E0B).opacity(0.36) : Color(hex: 0xF59E0B).opacity(0.30)
        while searchStart < plain.endIndex,
              let range = plain.range(of: query, options: .caseInsensitive, range: searchStart..<plain.endIndex) {
            if let attrRange = Range(range, in: attr) {
                attr[attrRange].backgroundColor = bg
            }
            searchStart = range.upperBound
        }
    }

    private static func inlineAttributed(
        _ raw: String,
        size: CGFloat = 14,
        weight: Font.Weight = .regular,
        color: Color,
        scheme: ColorScheme,
        highlightQuery: String,
        strikethrough: Bool = false
    ) -> AttributedString {
        var attr: AttributedString
        if (raw.contains("*") || raw.contains("_") || raw.contains("`") || raw.contains("~") || raw.contains("[")),
           let parsed = try? AttributedString(markdown: raw, options: parseOpts) {
            attr = parsed
        } else {
            attr = AttributedString(raw)
        }
        attr.font = .system(size: size, weight: weight)
        attr.foregroundColor = color
        if strikethrough {
            attr.strikethroughStyle = .single
        }
        applyInlineTags(to: &attr, scheme: scheme)
        applySearchHighlight(to: &attr, query: highlightQuery, scheme: scheme)
        return attr
    }

    private static func buildChunks(text: String, scheme: ColorScheme, highlightQuery: String, taskOffset: Int) -> [MarkdownChunk] {
        let rawLines = text.components(separatedBy: "\n")
        var out: [MarkdownChunk] = []
        var chunkId = 0
        var taskIdx = taskOffset

        let primary = FlomoPalette.textPrimary(scheme)
        let secondary = FlomoPalette.textSecondary(scheme)
        let muted = FlomoPalette.textMuted(scheme)
        let accent = FlomoPalette.accent(scheme)

        var textBuffer = AttributedString()
        var hasTextInBuffer = false

        func flushTextBuffer() {
            if hasTextInBuffer {
                out.append(.richText(id: chunkId, attributed: textBuffer))
                chunkId += 1
                textBuffer = AttributedString()
                hasTextInBuffer = false
            }
        }

        func appendLine(_ lineAttr: AttributedString) {
            if hasTextInBuffer {
                textBuffer.append(AttributedString("\n"))
            }
            textBuffer.append(lineAttr)
            hasTextInBuffer = true
        }

        var inCode = false
        var codeLang = ""
        var codeBuf: [String] = []

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !inCode {
                    flushTextBuffer()
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeBuf = []
                } else {
                    out.append(.codeBlock(id: chunkId, lang: codeLang, code: codeBuf.joined(separator: "\n")))
                    chunkId += 1
                    inCode = false
                    codeLang = ""
                    codeBuf = []
                }
                continue
            }
            if inCode {
                codeBuf.append(line)
                continue
            }

            let level = indentLevel(of: line)
            let indentStr = level > 0 ? String(repeating: "    ", count: level) : ""

            if trimmed.isEmpty {
                appendLine(AttributedString(""))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                var rule = AttributedString("────────────────────────")
                rule.font = .system(size: 12)
                rule.foregroundColor = muted.opacity(0.45)
                appendLine(rule)
            } else if trimmed.hasPrefix("#### ") {
                appendLine(inlineAttributed(String(trimmed.dropFirst(5)), size: 14.5, weight: .semibold, color: primary, scheme: scheme, highlightQuery: highlightQuery))
            } else if trimmed.hasPrefix("### ") {
                appendLine(inlineAttributed(String(trimmed.dropFirst(4)), size: 15, weight: .semibold, color: primary, scheme: scheme, highlightQuery: highlightQuery))
            } else if trimmed.hasPrefix("## ") {
                appendLine(inlineAttributed(String(trimmed.dropFirst(3)), size: 16.5, weight: .bold, color: primary, scheme: scheme, highlightQuery: highlightQuery))
            } else if trimmed.hasPrefix("# ") {
                appendLine(inlineAttributed(String(trimmed.dropFirst(2)), size: 18, weight: .bold, color: primary, scheme: scheme, highlightQuery: highlightQuery))
            } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                let done = !trimmed.hasPrefix("- [ ] ")
                let currentTaskIdx = taskIdx
                taskIdx += 1
                var row = AttributedString(indentStr)
                var box = AttributedString(done ? "☑ " : "☐ ")
                box.font = .system(size: 14.5)
                box.foregroundColor = done ? accent : muted
                if let url = URL(string: "whim-task://toggle/\(currentTaskIdx)") {
                    box.link = url
                }
                row.append(box)
                row.append(inlineAttributed(String(trimmed.dropFirst(6)), color: done ? secondary : primary, scheme: scheme, highlightQuery: highlightQuery, strikethrough: done))
                appendLine(row)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var row = AttributedString("\(indentStr)\(bulletSymbol(for: level)) ")
                row.font = .system(size: 14, weight: .bold)
                row.foregroundColor = secondary
                row.append(inlineAttributed(String(trimmed.dropFirst(2)), color: primary, scheme: scheme, highlightQuery: highlightQuery))
                appendLine(row)
            } else if let (num, bodyText) = parseOrderedList(trimmed) {
                var row = AttributedString("\(indentStr)\(num). ")
                row.font = .system(size: 13.5).monospacedDigit()
                row.foregroundColor = secondary
                row.append(inlineAttributed(bodyText, color: primary, scheme: scheme, highlightQuery: highlightQuery))
                appendLine(row)
            } else if trimmed.hasPrefix("> ") {
                var row = AttributedString("\(indentStr)▎ ")
                row.font = .system(size: 14, weight: .semibold)
                row.foregroundColor = accent.opacity(0.8)
                row.append(inlineAttributed(String(trimmed.dropFirst(2)), color: secondary, scheme: scheme, highlightQuery: highlightQuery))
                appendLine(row)
            } else {
                var row = indentStr.isEmpty ? AttributedString() : AttributedString(indentStr)
                row.append(inlineAttributed(trimmed, color: primary, scheme: scheme, highlightQuery: highlightQuery))
                appendLine(row)
            }
        }

        if inCode && !codeBuf.isEmpty {
            out.append(.codeBlock(id: chunkId, lang: codeLang, code: codeBuf.joined(separator: "\n")))
        } else {
            flushTextBuffer()
        }
        return out
    }
}

/// Counts how many markdown task items (`- [ ] ` / `- [x] `) exist in a text block.
func countMarkdownTasks(in text: String) -> Int {
    var count = 0
    var inCode = false
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            inCode.toggle()
            continue
        }
        if !inCode && (trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ")) {
            count += 1
        }
    }
    return count
}

/// Toggles the N-th markdown task checkbox in full note content and returns the updated markdown.
func toggleMarkdownTask(in content: String, index targetIndex: Int) -> String? {
    var lines = content.components(separatedBy: "\n")
    var idx = 0
    var inCode = false
    for i in lines.indices {
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            inCode.toggle()
            continue
        }
        if inCode { continue }
        if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
            if idx == targetIndex {
                if let range = lines[i].range(of: "- [ ] ") {
                    lines[i].replaceSubrange(range, with: "- [x] ")
                } else if let range = lines[i].range(of: "- [x] ") {
                    lines[i].replaceSubrange(range, with: "- [ ] ")
                } else if let range = lines[i].range(of: "- [X] ") {
                    lines[i].replaceSubrange(range, with: "- [ ] ")
                }
                return lines.joined(separator: "\n")
            }
            idx += 1
        }
    }
    return nil
}

/// High-performance Markdown renderer: keeps `#tag/subtag` inline with click-to-filter,
/// supports interactive task checkboxes and search keyword highlighting.
struct MarkdownBlockView: View, Equatable {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var highlightQuery: String = ""
    var taskOffset: Int = 0
    var onTapTag: ((String) -> Void)? = nil
    var onToggleTask: ((Int) -> Void)? = nil

    static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        lhs.text == rhs.text &&
        lhs.highlightQuery == rhs.highlightQuery &&
        lhs.taskOffset == rhs.taskOffset
    }

    var body: some View {
        let chunks = MarkdownRenderCache.chunks(for: text, scheme: scheme, highlightQuery: highlightQuery, taskOffset: taskOffset)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chunks) { chunk in
                switch chunk {
                case .richText(_, let attr):
                    Text(attr)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if url.scheme == "whim-tag" {
                                let rawPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                let decoded = rawPath.removingPercentEncoding ?? rawPath
                                if !decoded.isEmpty {
                                    onTapTag?(decoded)
                                }
                                return .handled
                            }
                            if url.scheme == "whim-task" {
                                let rawIdx = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                if let idx = Int(rawIdx) {
                                    onToggleTask?(idx)
                                }
                                return .handled
                            }
                            return .systemAction
                        })
                case .codeBlock(_, let lang, let code):
                    VStack(alignment: .leading, spacing: 4) {
                        if !lang.isEmpty {
                            Text(lang)
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundColor(FlomoPalette.textMuted(scheme))
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(FlomoPalette.canvas(scheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(FlomoPalette.border(scheme), lineWidth: 0.8)
                    )
                }
            }
        }
    }
}
