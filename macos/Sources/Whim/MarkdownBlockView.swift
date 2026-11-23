import SwiftUI

/// Lightweight Markdown renderer for Whim note cards:
/// supports fenced code blocks (```), horizontal rules (---), # / ## / ### / #### headings,
/// nested unordered lists (- / *), nested ordered lists (1.), nested task checkboxes (- [ ] / - [x]),
/// > quotes, **bold**, *italic*, ~~strike~~, `code`, and [links](url).
struct MarkdownBlockView: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let collapsed: Bool

    private enum Segment: Identifiable {
        case line(id: Int, text: String)
        case codeBlock(id: Int, lang: String, code: String)

        var id: Int {
            switch self {
            case .line(let id, _): return id
            case .codeBlock(let id, _, _): return id
            }
        }
    }

    private var segments: [Segment] {
        let rawLines = text.components(separatedBy: "\n")
        let effectiveLines = collapsed ? Array(rawLines.prefix(6)) : rawLines
        var out: [Segment] = []
        var inCode = false
        var codeLang = ""
        var codeBuf: [String] = []
        var segId = 0

        for line in effectiveLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !inCode {
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeBuf = []
                } else {
                    out.append(.codeBlock(id: segId, lang: codeLang, code: codeBuf.joined(separator: "\n")))
                    segId += 1
                    inCode = false
                    codeLang = ""
                    codeBuf = []
                }
                continue
            }
            if inCode {
                codeBuf.append(line)
            } else {
                out.append(.line(id: segId, text: line))
                segId += 1
            }
        }
        if inCode && !codeBuf.isEmpty {
            out.append(.codeBlock(id: segId, lang: codeLang, code: codeBuf.joined(separator: "\n")))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(segments) { seg in
                switch seg {
                case .line(_, let line):
                    renderLine(line)
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
        .textSelection(.enabled)
    }

    private func indentLevel(of line: String) -> Int {
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

    private func bulletSymbol(for level: Int) -> String {
        switch level % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        let level = indentLevel(of: line)
        let indentPx = CGFloat(level) * 18
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            Rectangle()
                .fill(FlomoPalette.border(scheme))
                .frame(height: 1)
                .padding(.vertical, 4)
        } else if trimmed.hasPrefix("#### ") {
            inlineMarkdownText(String(trimmed.dropFirst(5)), size: 14.5, weight: .semibold)
                .padding(.top, 2)
        } else if trimmed.hasPrefix("### ") {
            inlineMarkdownText(String(trimmed.dropFirst(4)), size: 15, weight: .semibold)
                .padding(.top, 3)
        } else if trimmed.hasPrefix("## ") {
            inlineMarkdownText(String(trimmed.dropFirst(3)), size: 16.5, weight: .bold)
                .padding(.top, 4)
        } else if trimmed.hasPrefix("# ") {
            inlineMarkdownText(String(trimmed.dropFirst(2)), size: 18, weight: .bold)
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
            let done = !trimmed.hasPrefix("- [ ] ")
            let bodyText = String(trimmed.dropFirst(6))
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12.5))
                    .foregroundColor(done ? FlomoPalette.accent(scheme) : FlomoPalette.textMuted(scheme))
                inlineMarkdownText(
                    bodyText,
                    color: done ? FlomoPalette.textSecondary(scheme) : FlomoPalette.textPrimary(scheme)
                )
                .strikethrough(done)
            }
            .padding(.leading, indentPx)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let bodyText = String(trimmed.dropFirst(2))
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(bulletSymbol(for: level))
                    .font(.system(size: level == 0 ? 14 : 13, weight: .bold))
                    .foregroundColor(FlomoPalette.textSecondary(scheme))
                    .frame(width: 12, alignment: .center)
                inlineMarkdownText(bodyText)
            }
            .padding(.leading, indentPx)
        } else if let (num, bodyText) = parseOrderedList(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(num).")
                    .font(.system(size: 13.5).monospacedDigit())
                    .foregroundColor(FlomoPalette.textSecondary(scheme))
                    .frame(minWidth: 18, alignment: .trailing)
                inlineMarkdownText(bodyText)
            }
            .padding(.leading, indentPx)
        } else if trimmed.hasPrefix("> ") {
            let bodyText = String(trimmed.dropFirst(2))
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(FlomoPalette.accent(scheme).opacity(0.75))
                    .frame(width: 3)
                inlineMarkdownText(bodyText, color: FlomoPalette.textSecondary(scheme))
            }
            .padding(.vertical, 2)
            .padding(.leading, indentPx)
        } else {
            inlineMarkdownText(trimmed)
                .padding(.leading, indentPx)
        }
    }

    private func inlineMarkdownText(
        _ raw: String,
        size: CGFloat = 14,
        weight: Font.Weight = .regular,
        color: Color? = nil
    ) -> Text {
        let fg = color ?? FlomoPalette.textPrimary(scheme)
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attr = try? AttributedString(markdown: raw, options: opts) {
            return Text(attr)
                .font(.system(size: size, weight: weight))
                .foregroundColor(fg)
        }
        return Text(raw)
            .font(.system(size: size, weight: weight))
            .foregroundColor(fg)
    }

    private func parseOrderedList(_ s: String) -> (String, String)? {
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let prefix = s[..<dot]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return nil }
        let afterDot = s.index(after: dot)
        guard afterDot < s.endIndex, s[afterDot] == " " else { return nil }
        let body = String(s[s.index(after: afterDot)...])
        return (String(prefix), body)
    }
}
