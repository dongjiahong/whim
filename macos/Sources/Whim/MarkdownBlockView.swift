import SwiftUI

/// Lightweight Markdown renderer for Whim note cards:
/// supports **bold**, *italic*, ~~strike~~, `inline code`, clickable [links](url),
/// unordered lists (- / *), ordered lists (1.), task checkboxes (- [ ] / - [x]), and > quotes.
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

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
            let done = !trimmed.hasPrefix("- [ ] ")
            let bodyText = String(trimmed.dropFirst(6))
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12.5))
                    .foregroundColor(done ? FlomoPalette.accent(scheme) : FlomoPalette.textMuted(scheme))
                inlineMarkdownText(bodyText)
                    .strikethrough(done)
                    .foregroundColor(done ? FlomoPalette.textSecondary(scheme) : FlomoPalette.textPrimary(scheme))
            }
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let bodyText = String(trimmed.dropFirst(2))
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(FlomoPalette.textSecondary(scheme))
                inlineMarkdownText(bodyText)
            }
        } else if let (num, bodyText) = parseOrderedList(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(num).")
                    .font(.system(size: 13.5).monospacedDigit())
                    .foregroundColor(FlomoPalette.textSecondary(scheme))
                    .frame(minWidth: 18, alignment: .trailing)
                inlineMarkdownText(bodyText)
            }
        } else if trimmed.hasPrefix("> ") {
            let bodyText = String(trimmed.dropFirst(2))
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(FlomoPalette.accent(scheme).opacity(0.75))
                    .frame(width: 3)
                inlineMarkdownText(bodyText)
                    .foregroundColor(FlomoPalette.textSecondary(scheme))
            }
            .padding(.vertical, 2)
        } else if trimmed.hasPrefix("### ") {
            inlineMarkdownText(String(trimmed.dropFirst(4)))
                .font(.system(size: 15, weight: .semibold))
        } else if trimmed.hasPrefix("## ") {
            inlineMarkdownText(String(trimmed.dropFirst(3)))
                .font(.system(size: 16, weight: .semibold))
        } else {
            inlineMarkdownText(line)
        }
    }

    private func inlineMarkdownText(_ raw: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attr = try? AttributedString(markdown: raw, options: opts) {
            return Text(attr)
                .font(.system(size: 14))
                .foregroundColor(FlomoPalette.textPrimary(scheme))
        }
        return Text(raw)
            .font(.system(size: 14))
            .foregroundColor(FlomoPalette.textPrimary(scheme))
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
