import SwiftUI

/// Lightweight Markdown renderer for Whim note cards:
/// supports # / ## / ### / #### headings, nested unordered lists (- / *), nested ordered lists (1.),
/// nested task checkboxes (- [ ] / - [x]), > quotes, **bold**, *italic*, ~~strike~~, `code`, and [links](url).
struct MarkdownBlockView: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let collapsed: Bool

    private var lines: [String] {
        let raw = text.components(separatedBy: "\n")
        return collapsed ? Array(raw.prefix(6)) : raw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                renderLine(line)
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
