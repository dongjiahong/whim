import AppKit
import SwiftUI

struct ImageLightboxState: Identifiable, Equatable {
    let id = UUID()
    let paths: [String]
    let initialIndex: Int
}

struct ImageLightboxView: View {
    @Environment(\.colorScheme) private var scheme
    let paths: [String]
    let initialIndex: Int
    let onClose: () -> Void

    @State private var currentIndex: Int
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var copiedHint: Bool = false

    init(paths: [String], initialIndex: Int, onClose: @escaping () -> Void) {
        self.paths = paths
        self.initialIndex = max(0, min(initialIndex, max(0, paths.count - 1)))
        self.onClose = onClose
        _currentIndex = State(initialValue: max(0, min(initialIndex, max(0, paths.count - 1))))
    }

    private var currentPath: String? {
        guard paths.indices.contains(currentIndex) else { return nil }
        return paths[currentIndex]
    }

    private func resetTransform() {
        withAnimation(.easeOut(duration: 0.16)) {
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }

    private func stepImage(_ delta: Int) {
        guard paths.count > 1 else { return }
        let next = (currentIndex + delta + paths.count) % paths.count
        currentIndex = next
        resetTransform()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                if paths.count > 1 {
                    Text("\(currentIndex + 1) / \(paths.count)")
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                } else {
                    Text("图片预览")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                }

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scale = max(1.0, scale - 0.5)
                            lastScale = scale
                            if scale <= 1.01 { offset = .zero; lastOffset = .zero }
                        }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
                    .disabled(scale <= 1.0)

                    Text("\(Int(scale * 100))%")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                        .frame(width: 44)
                        .onTapGesture { resetTransform() }

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scale = min(4.0, scale + 0.5)
                            lastScale = scale
                        }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 13))
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
                    .disabled(scale >= 4.0)
                }

                if let path = currentPath, let img = NSImage(contentsOfFile: path) {
                    WhimSecondaryButton(title: copiedHint ? "已复制" : "复制图片", icon: copiedHint ? "checkmark" : "doc.on.doc", compact: true) {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.writeObjects([img])
                        copiedHint = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedHint = false }
                    }
                }

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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.25)

            // Main zoomable image canvas
            ZStack {
                Color.black.opacity(scheme == .dark ? 0.45 : 0.06)

                if let path = currentPath, let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = max(1.0, min(4.0, lastScale * value))
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    if scale <= 1.02 { resetTransform() }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard scale > 1.01 else { return }
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                        .onTapGesture(count: 2) {
                            if scale > 1.05 {
                                resetTransform()
                            } else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    scale = 2.2
                                    lastScale = 2.2
                                }
                            }
                        }
                        .padding(16)
                }

                if paths.count > 1 {
                    HStack {
                        Button { stepImage(-1) } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.leftArrow, modifiers: [])

                        Spacer()

                        Button { stepImage(1) } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .padding(.horizontal, 16)
                }
            }
            .frame(minWidth: 680, idealWidth: 880, maxWidth: 1120, minHeight: 460, idealHeight: 620, maxHeight: 780)
            .clipped()

            // Thumbnail strip when multiple images
            if paths.count > 1 {
                Divider().opacity(0.25)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(paths.enumerated()), id: \.offset) { idx, p in
                            if let thumb = NSImage(contentsOfFile: p) {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(idx == currentIndex ? FlomoPalette.accent(scheme) : Color.clear, lineWidth: 2)
                                    )
                                    .opacity(idx == currentIndex ? 1.0 : 0.6)
                                    .onTapGesture {
                                        currentIndex = idx
                                        resetTransform()
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(FlomoPalette.card(scheme))
    }
}
