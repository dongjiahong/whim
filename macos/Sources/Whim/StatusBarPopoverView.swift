import AppKit
import SwiftUI

struct StatusBarPopoverView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: WhimStoreVM
    let onNewNote: () -> Void
    let onOpenMainWindow: () -> Void
    let onSelectTag: (String) -> Void
    let onSyncNow: () -> Void
    let onQuit: () -> Void

    @State private var copied: Bool = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func formatMs(_ ms: Int64) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top section: First Pinned Note Widget Box
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(FlomoPalette.accent(scheme))
                    Text("置顶笔记")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                    if let note = vm.topPinnedNote {
                        Text("· \(formatMs(note.createdAt))")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundColor(FlomoPalette.textMuted(scheme))
                            .lineLimit(1)
                    }
                    Spacer()
                    if let note = vm.topPinnedNote {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(note.content, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copied = false
                            }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10.5))
                                .foregroundColor(copied ? FlomoPalette.accent(scheme) : FlomoPalette.textMuted(scheme))
                                .frame(width: 22, height: 22)
                                .whimClickable(cornerRadius: 5, hoverFill: true)
                        }
                        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 5))
                        .help("复制置顶笔记")
                    }
                }

                if let note = vm.topPinnedNote {
                    let noteBody = FlomoNoteCardBody(
                        noteId: note.id,
                        updatedAt: note.updatedAt,
                        content: note.content,
                        attachments: note.attachments ?? [],
                        onTapTag: { path in
                            onSelectTag(path)
                        },
                        onTapImages: { _, _ in
                            onOpenMainWindow()
                        },
                        onToggleTask: { taskIdx in
                            vm.toggleTaskCheckbox(note, taskIndex: taskIdx)
                        }
                    )
                    .equatable()

                    ViewThatFits(in: .vertical) {
                        noteBody
                        ScrollView(showsIndicators: true) {
                            noteBody
                                .padding(.trailing, 4)
                        }
                        .frame(height: 340)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(FlomoPalette.card(scheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(FlomoPalette.accent(scheme).opacity(0.32), lineWidth: 0.9)
                    )
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("暂无置顶笔记")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                        Text("在任意笔记卡片菜单中点击「置顶笔记」，即可固定显示在这里。")
                            .font(.system(size: 11.5))
                            .foregroundColor(FlomoPalette.textMuted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(FlomoPalette.card(scheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(FlomoPalette.border(scheme), lineWidth: 0.6)
                    )
                }
            }
            .padding(12)

            Divider().opacity(0.28)

            // Bottom section: Quick Menu Actions
            VStack(spacing: 2) {
                StatusBarMenuRow(
                    icon: "square.and.pencil",
                    title: "新建闪念",
                    shortcut: "⌘⇧J",
                    action: onNewNote
                )
                StatusBarMenuRow(
                    icon: "macwindow",
                    title: "打开主窗口",
                    action: onOpenMainWindow
                )
                StatusBarMenuRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: vm.isSyncing ? "正在同步..." : "立即同步",
                    disabled: vm.isSyncing,
                    action: onSyncNow
                )

                Divider()
                    .opacity(0.28)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)

                StatusBarMenuRow(
                    icon: "power",
                    title: "退出 Whim",
                    shortcut: "⌘Q",
                    action: onQuit
                )
            }
            .padding(6)
        }
        .frame(width: 640)
        .background(FlomoPalette.canvas(scheme))
    }
}

private struct StatusBarMenuRow: View {
    @Environment(\.colorScheme) private var scheme
    let icon: String
    let title: String
    var shortcut: String? = nil
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12.5))
                    .foregroundColor(disabled ? FlomoPalette.textMuted(scheme) : FlomoPalette.textSecondary(scheme))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(disabled ? FlomoPalette.textMuted(scheme) : FlomoPalette.textPrimary(scheme))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered && !disabled ? FlomoPalette.hoverFill(scheme) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6, pressScale: 0.99))
        .disabled(disabled)
        .onHover { hovering in
            isHovered = hovering
            if hovering && !disabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if isHovered { isHovered = false; NSCursor.pop() }
        }
    }
}
