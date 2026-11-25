import SwiftUI

struct NoteThreadSheet: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: WhimStoreVM
    let parentNote: WhimNote
    let onTapTag: (String) -> Void
    let onTapImages: ([String], Int) -> Void
    let onClose: () -> Void

    @State private var replies: [WhimNote] = []
    @State private var draft: String = ""
    @State private var isLoading: Bool = true
    @State private var isSubmitting: Bool = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func formatMs(_ ms: Int64) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0))
    }

    private func loadReplies() {
        isLoading = true
        vm.loadReplies(parentId: parentNote.id) { items in
            self.replies = items
            self.isLoading = false
        }
    }

    private func submitReply() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        vm.createReply(parentId: parentNote.id, content: trimmed) { created in
            self.isSubmitting = false
            if let created {
                self.draft = ""
                self.replies.append(created)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 13))
                        .foregroundColor(FlomoPalette.accent(scheme))
                    Text("笔记追记")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(FlomoPalette.textPrimary(scheme))
                    Text("\(replies.count) 条")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                        .frame(width: 28, height: 28)
                        .whimClickable(cornerRadius: 7, hoverFill: true)
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Parent Note Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text(formatMs(parentNote.createdAt))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                        MarkdownBlockView(text: parentNote.content, onTapTag: onTapTag)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(FlomoPalette.card(scheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(FlomoPalette.accent(scheme).opacity(0.35), lineWidth: 1)
                    )

                    // Replies timeline
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在加载追记...")
                                .font(.system(size: 12))
                                .foregroundColor(FlomoPalette.textMuted(scheme))
                        }
                        .padding(.vertical, 12)
                    } else if replies.isEmpty {
                        Text("还没有追记。在下方写下新的思考，按时间线串连成脉络。")
                            .font(.system(size: 12.5))
                            .foregroundColor(FlomoPalette.textMuted(scheme))
                            .padding(.vertical, 12)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(replies) { reply in
                                HStack(alignment: .top, spacing: 10) {
                                    Rectangle()
                                        .fill(FlomoPalette.accent(scheme).opacity(0.45))
                                        .frame(width: 2)
                                        .cornerRadius(1)
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(formatMs(reply.createdAt))
                                                .font(.system(size: 11.5).monospacedDigit())
                                                .foregroundColor(FlomoPalette.textMuted(scheme))
                                            Spacer()
                                            Button {
                                                vm.deleteNote(reply)
                                                replies.removeAll { $0.id == reply.id }
                                            } label: {
                                                Image(systemName: "trash")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(FlomoPalette.textMuted(scheme))
                                                    .frame(width: 22, height: 22)
                                                    .whimClickable(cornerRadius: 5, hoverFill: true)
                                            }
                                            .buttonStyle(WhimTactileButtonStyle(cornerRadius: 5))
                                            .help("删除这条追记")
                                        }
                                        MarkdownBlockView(text: reply.content, onTapTag: onTapTag)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(FlomoPalette.card(scheme))
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }

            Divider().opacity(0.25)

            // Bottom reply composer
            VStack(spacing: 8) {
                TextEditor(text: $draft)
                    .font(.system(size: 13.5))
                    .foregroundColor(FlomoPalette.textPrimary(scheme))
                    .scrollContentBackground(.hidden)
                    .frame(height: 76)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(FlomoPalette.composer(scheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(FlomoPalette.border(scheme), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("补充一条追记...")
                                .font(.system(size: 13.5))
                                .foregroundColor(FlomoPalette.textMuted(scheme))
                                .padding(.top, 10)
                                .padding(.leading, 13)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Text("⌘↩ 发送追记")
                        .font(.system(size: 11))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                    Spacer()
                    WhimPrimaryButton(
                        title: isSubmitting ? "发送中..." : "添加追记",
                        icon: "paperplane.fill",
                        compact: true
                    ) {
                        submitReply()
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(14)
            .background(FlomoPalette.card(scheme))
        }
        .frame(width: 560, height: 560)
        .background(FlomoPalette.canvas(scheme))
        .onAppear { loadReplies() }
    }
}
