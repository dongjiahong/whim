import SwiftUI

struct TagRenameSheet: View {
    @Environment(\.colorScheme) private var scheme
    let oldTag: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var newTag: String

    init(oldTag: String, onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.oldTag = oldTag
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _newTag = State(initialValue: oldTag)
    }

    private var cleanedNew: String {
        newTag.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }

    private var canSubmit: Bool {
        !cleanedNew.isEmpty && cleanedNew != oldTag
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("重命名 / 合并标签")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FlomoPalette.textPrimary(scheme))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12.5))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                        .frame(width: 26, height: 26)
                        .whimClickable(cornerRadius: 6, hoverFill: true)
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("原标签")
                    .font(.system(size: 11.5))
                    .foregroundColor(FlomoPalette.textMuted(scheme))
                Text("#\(oldTag)")
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .foregroundColor(FlomoPalette.tagText(scheme))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(FlomoPalette.tagBg(scheme)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("新标签路径（输入已有标签将自动合并，子标签同步迁移）")
                    .font(.system(size: 11.5))
                    .foregroundColor(FlomoPalette.textMuted(scheme))
                HStack(spacing: 4) {
                    Text("#")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                    TextField("例如：工作/系统架构", text: $newTag)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .foregroundColor(FlomoPalette.textPrimary(scheme))
                        .onSubmit {
                            if canSubmit { onConfirm(cleanedNew) }
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(FlomoPalette.canvas(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(FlomoPalette.border(scheme), lineWidth: 1))
            }

            HStack {
                Spacer()
                WhimSecondaryButton(title: "取消", compact: true, action: onCancel)
                WhimPrimaryButton(title: "确认修改", compact: true) {
                    onConfirm(cleanedNew)
                }
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 390)
        .background(FlomoPalette.card(scheme))
    }
}
