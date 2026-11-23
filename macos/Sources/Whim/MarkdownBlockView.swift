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

    static func chunks(for text: String, collapsed: Bool, scheme: ColorScheme) -> [MarkdownChunk] {
        let isDark = scheme == .dark
        let key = "\(isDark ? "d" : "l")|\(collapsed ? "1" : "0")|\(text)" as NSString
        if let hit = chunkCache.object(forKey: key) {
            return hit.chunks
        }
        let parsed = buildChunks(text: text, collapsed: collapsed, scheme: scheme)
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

    private static func inlineAttributed(
        _ raw: String,
        size: CGFloat = 14,
        weight: Font.Weight = .regular,
        color: Color,
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
        return attr
    }

    private static func buildChunks(text: String, collapsed: Bool, scheme: ColorScheme) -> [MarkdownChunk] {
        let rawLines = text.components(separatedBy: "\n")
        let effectiveLines = collapsed ? Array(rawLines.prefix(6)) : rawLines
        var out: [MarkdownChunk] = []
        var chunkId = 0

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

        for line in effectiveLines {
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
                appendLine(inlineAttributed(String(trimmed.dropFirst(5)), size: 14.5, weight: .semibold, color: primary))
            } else if trimmed.hasPrefix("### ") {
                appendLine(inlineAttributed(String(trimmed.dropFirst(4)), size: 15, weight: .semibold, color: primary))
            } else if trimmed.hasPrefix("## ") {
                appendLine(inlineAttributed(String(trimmed.dropFirst(3)), size: 16.5, weight: .bold, color: primary))
            } else if trimmed.hasPrefix("# ") {
                appendLine(inlineAttributed(String(trimmed.dropFirst(2)), size: 18, weight: .bold, color: primary))
            } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                let done = !trimmed.hasPrefix("- [ ] ")
                var row = AttributedString("\(indentStr)\(done ? "☑" : "☐") ")
                row.font = .system(size: 14)
                row.foregroundColor = done ? accent : muted
                row.append(inlineAttributed(String(trimmed.dropFirst(6)), color: done ? secondary : primary, strikethrough: done))
                appendLine(row)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var row = AttributedString("\(indentStr)\(bulletSymbol(for: level)) ")
                row.font = .system(size: 14, weight: .bold)
                row.foregroundColor = secondary
                row.append(inlineAttributed(String(trimmed.dropFirst(2)), color: primary))
                appendLine(row)
            } else if let (num, bodyText) = parseOrderedList(trimmed) {
                var row = AttributedString("\(indentStr)\(num). ")
                row.font = .system(size: 13.5).monospacedDigit()
                row.foregroundColor = secondary
                row.append(inlineAttributed(bodyText, color: primary))
                appendLine(row)
            } else if trimmed.hasPrefix("> ") {
                var row = AttributedString("\(indentStr)▎ ")
                row.font = .system(size: 14, weight: .semibold)
                row.foregroundColor = accent.opacity(0.8)
                row.append(inlineAttributed(String(trimmed.dropFirst(2)), color: secondary))
                appendLine(row)
            } else {
                var row = indentStr.isEmpty ? AttributedString() : AttributedString(indentStr)
                row.append(inlineAttributed(trimmed, color: primary))
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

/// High-performance Markdown renderer: merges contiguous text lines into a single cached
/// AttributedString + Text view so scrolling renders 1 view per block instead of 10-25.
struct MarkdownBlockView: View, Equatable {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let collapsed: Bool

    static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        lhs.text == rhs.text && lhs.collapsed == rhs.collapsed
    }

    var body: some View {
        let chunks = MarkdownRenderCache.chunks(for: text, collapsed: collapsed, scheme: scheme)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chunks) { chunk in
                switch chunk {
                case .richText(_, let attr):
                    Text(attr)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
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
