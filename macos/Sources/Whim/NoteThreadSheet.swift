import SwiftUI

struct NoteThreadSheet: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: WhimStoreVM
    let parentNote: WhimNote
    let onTapTag: (String) -> Void
    let onTapImages: ([String], Int) -> Void
    let onClose: () -> Void

    @StateObject private var editor = InlineEditorController()
    @State private var replies: [WhimNote] = []
    @State private var draft: String = ""
    @State private var attachments: [WhimAttachment] = []
    @State private var isFocused: Bool = false
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

    private var canSubmit: Bool {
        !isSubmitting && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func loadReplies() {
        isLoading = true
        vm.loadReplies(parentId: parentNote.id) { items in
            self.replies = items
            self.isLoading = false
        }
    }

    private func submitReply() {
        let (md, atts) = editor.serialize()
        let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !atts.isEmpty), !isSubmitting else { return }
        isSubmitting = true
        vm.createReply(parentId: parentNote.id, content: trimmed, attachments: atts) { created in
            self.isSubmitting = false
            if let created {
                self.editor.clear()
                self.draft = ""
                self.attachments = []
                self.replies.append(created)
                self.editor.focus()
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
                    // Parent Note Card (supports inline images just like feed cards)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(formatMs(parentNote.createdAt))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                        FlomoNoteCardBody(
                            noteId: parentNote.id,
                            updatedAt: parentNote.updatedAt,
                            content: parentNote.content,
                            attachments: parentNote.attachments ?? [],
                            onTapTag: onTapTag,
                            onTapImages: onTapImages
                        )
                        .equatable()
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
                        Text("还没有追记。在下方写下新的思考或粘贴图片，按时间线串连成脉络。")
                            .font(.system(size: 12.5))
                            .foregroundColor(FlomoPalette.textMuted(scheme))
                            .padding(.vertical, 12)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(replies.enumerated()), id: \.element.id) { idx, reply in
                                HStack(alignment: .top, spacing: 10) {
                                    Rectangle()
                                        .fill(FlomoPalette.accent(scheme).opacity(0.45))
                                        .frame(width: 2)
                                        .cornerRadius(1)
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 6) {
                                            Text("追记 #\(idx + 1)")
                                                .font(.system(size: 10.5, weight: .semibold))
                                                .foregroundColor(FlomoPalette.accent(scheme))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1.5)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                        .fill(FlomoPalette.accentSoft(scheme))
                                                )
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
                                        FlomoNoteCardBody(
                                            noteId: reply.id,
                                            updatedAt: reply.updatedAt,
                                            content: reply.content,
                                            attachments: reply.attachments ?? [],
                                            onTapTag: onTapTag,
                                            onTapImages: onTapImages
                                        )
                                        .equatable()
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

            // Bottom rich reply composer (supports inline Cmd+V images & Finder picker just like main composer)
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("补充一条追记...（直接 ⌘V 可在光标处插入图片）")
                            .font(.system(size: 13.5))
                            .foregroundColor(FlomoPalette.textMuted(scheme))
                            .padding(.top, 5)
                            .padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                    InlineRichEditor(
                        controller: editor,
                        autoFocus: true,
                        isDark: scheme == .dark,
                        onTextChange: { md, atts in
                            draft = md
                            attachments = atts
                        },
                        onFocusChange: { focused in isFocused = focused },
                        onSubmit: submitReply,
                        onEscape: onClose
                    )
                    .frame(height: !attachments.isEmpty ? 160 : 92)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(FlomoPalette.composer(scheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isFocused ? FlomoPalette.accent(scheme) : FlomoPalette.border(scheme), lineWidth: isFocused ? 1.2 : 1)
                )

                HStack(spacing: 8) {
                    Button {
                        editor.insertSnippet(draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "#" : " #")
                        editor.focus()
                    } label: {
                        Image(systemName: "number")
                            .font(.system(size: 14))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                            .frame(width: 28, height: 26)
                            .whimClickable(cornerRadius: 6, hoverFill: true)
                    }
                    .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
                    .help("插入标签 (#)")

                    Button {
                        editor.pickImageFromFinder()
                    } label: {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                            .frame(width: 28, height: 26)
                            .whimClickable(cornerRadius: 6, hoverFill: true)
                    }
                    .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
                    .help("从本地选择图片插入光标处（剪贴板图片直接 ⌘V）")

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
                    .disabled(!canSubmit)
                }
            }
            .padding(14)
            .background(FlomoPalette.card(scheme))
        }
        .frame(width: 580, height: 600)
        .background(FlomoPalette.canvas(scheme))
        .onAppear { loadReplies() }
    }
}
