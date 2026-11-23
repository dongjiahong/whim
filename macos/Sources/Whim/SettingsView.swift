import AppKit
import SwiftUI

enum AppThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case shortcuts = "快捷键"
    case review = "每日回顾"
    case sync = "局域网同步"
    case mcp = "MCP / 导出"
    case about = "关于与更新"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .review: return "sparkles"
        case .sync: return "arrow.triangle.2.circlepath"
        case .mcp: return "chevron.left.forwardslash.chevron.right"
        case .about: return "info.circle"
        }
    }
}

struct SettingsModalView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: WhimStoreVM
    @Binding var themeModeRaw: String
    var initialSection: SettingsSection = .general
    let onApplyTheme: (AppThemeMode) -> Void
    let onClose: () -> Void

    @State private var activeSection: SettingsSection = .general
    @State private var remoteAddrInput: String = ""
    @State private var remoteCodeInput: String = ""
    @State private var copiedLocalCode: Bool = false
    @State private var showRegenerateConfirm: Bool = false
    @State private var copiedMCP: Bool = false
    @StateObject private var updater = GitHubUpdater()

    private var themeMode: AppThemeMode {
        AppThemeMode(rawValue: themeModeRaw) ?? .system
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar (flomo settings style)
            VStack(alignment: .leading, spacing: 6) {
                Text("设置")
                    .font(.system(size: 12))
                    .foregroundColor(FlomoPalette.textMuted(scheme))
                    .padding(.leading, 10)
                    .padding(.bottom, 6)

                ForEach(SettingsSection.allCases) { sec in
                    let active = activeSection == sec
                    Button { activeSection = sec } label: {
                        HStack(spacing: 10) {
                            Image(systemName: sec.icon)
                                .font(.system(size: 13))
                                .foregroundColor(active ? .white : FlomoPalette.textSecondary(scheme))
                                .frame(width: 18)
                            Text(sec.rawValue)
                                .font(.system(size: 13.5, weight: active ? .medium : .regular))
                                .foregroundColor(active ? .white : FlomoPalette.textPrimary(scheme))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? FlomoPalette.accent(scheme) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("Whim v\(GitHubUpdater.currentVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(FlomoPalette.textMuted(scheme))
                    .padding(.leading, 10)
            }
            .padding(16)
            .frame(width: 196)
            .background(FlomoPalette.sidebar(scheme))

            // Right Detail Area
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(activeSection.rawValue)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(FlomoPalette.textPrimary(scheme))
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        switch activeSection {
                        case .general: generalTab
                        case .shortcuts: shortcutsTab
                        case .review: reviewTab
                        case .sync: syncTab
                        case .mcp: mcpTab
                        case .about: aboutTab
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlomoPalette.canvas(scheme))
        }
        .frame(width: 680, height: 540)
        .preferredColorScheme(themeMode.colorScheme)
        .onAppear {
            activeSection = initialSection
            vm.refreshSyncState()
        }
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(spacing: 14) {
            settingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("外观主题")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text("支持浅色、深色或自动跟随 macOS 系统外观")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { themeMode },
                        set: { newMode in
                            themeModeRaw = newMode.rawValue
                            onApplyTheme(newMode)
                        }
                    )) {
                        ForEach(AppThemeMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }

            settingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开发期示例数据")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text("快速注入或一键清除带 #示例 标签的测试闪念")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                    }
                    Spacer()
                    Button("注入示例") { vm.seedSampleNotes() }
                    Button("清除示例") { vm.clearSampleNotes() }
                }
            }
        }
    }

    // MARK: - Shortcuts (mirrors flomo's clean card list)

    private var shortcutsTab: some View {
        settingsCard {
            VStack(spacing: 0) {
                shortcutRow("新建悬浮输入窗（全局）", keys: "⌘ + ⇧ + J")
                rowDivider
                shortcutRow("发布笔记", keys: "⌘ + Enter")
                rowDivider
                shortcutRow("换行", keys: "Enter")
                rowDivider
                shortcutRow("光标处粘贴内联图片", keys: "⌘ + V")
                rowDivider
                shortcutRow("搜索笔记与标签", keys: "⌘ + K")
                rowDivider
                shortcutRow("打开偏好设置", keys: "⌘ + ,")
                rowDivider
                shortcutRow("关闭未固定浮窗", keys: "Esc")
            }
        }
    }

    // MARK: - Daily Review

    private var reviewTab: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("开启每日晚间复盘提醒", isOn: $vm.dailyReviewEnabled)
                    .font(.system(size: 13.5))
                    .foregroundColor(FlomoPalette.textPrimary(scheme))
                    .onChange(of: vm.dailyReviewEnabled) { _, _ in vm.saveReviewSchedule() }

                HStack {
                    Text("提醒时间")
                        .font(.system(size: 13.5))
                        .foregroundColor(FlomoPalette.textPrimary(scheme))
                    Spacer()
                    Picker("时", selection: $vm.reviewHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d 时", h)).tag(h)
                        }
                    }
                    .frame(width: 86)
                    .onChange(of: vm.reviewHour) { _, _ in vm.saveReviewSchedule() }

                    Picker("分", selection: $vm.reviewMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { m in
                            Text(String(format: "%02d 分", m)).tag(m)
                        }
                    }
                    .frame(width: 86)
                    .onChange(of: vm.reviewMinute) { _, _ in vm.saveReviewSchedule() }
                }
                .disabled(!vm.dailyReviewEnabled)

                Text("提醒通过 macOS 系统通知中心送达，Android 端通过 AlarmManager 即使杀进程也可准时触发。")
                    .font(.system(size: 12))
                    .foregroundColor(FlomoPalette.textSecondary(scheme))
            }
        }
    }

    // MARK: - LAN Sync (Navigator-style Zero-IP UDP Discovery + Single Library Code)

    private var syncTab: some View {
        VStack(spacing: 16) {
            settingsCard {
                VStack(spacing: 14) {
                    // Big centered 6-digit code
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(vm.pairCode, forType: .string)
                        copiedLocalCode = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLocalCode = false }
                    } label: {
                        Text(formatSixDigit(vm.pairCode))
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .tracking(4)
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                    }
                    .buttonStyle(.plain)
                    .help(copiedLocalCode ? "已复制配对码" : "点击复制 6 位配对码")

                    Text(copiedLocalCode ? "已复制到剪贴板" : "在手机或另一台 Mac 的同步设置里输入这 6 位数字。同一份笔记库只需要一个码。")
                        .font(.system(size: 12.5))
                        .foregroundColor(copiedLocalCode ? FlomoPalette.accent(scheme) : FlomoPalette.textSecondary(scheme))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    rowDivider

                    // Auto-discovered UDP devices list
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("设备")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                            Spacer()
                            Button(vm.isSyncing ? "扫描中..." : "刷新") {
                                vm.syncNow()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.tagText(scheme))
                            .disabled(vm.isSyncing)
                        }

                        if vm.peerStatuses.isEmpty {
                            Text(vm.isSyncing ? "正在通过 UDP 自动发现同局域网设备..." : "暂未发现同一 Wi-Fi 下的其他 Whim 设备")
                                .font(.system(size: 12.5))
                                .foregroundColor(FlomoPalette.textMuted(scheme))
                                .padding(.vertical, 4)
                        } else {
                            ForEach(vm.peerStatuses) { peer in
                                HStack {
                                    Text(peer.displayName.isEmpty ? peer.addr : "\(peer.displayName) · \(peer.addr)")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(FlomoPalette.textPrimary(scheme))
                                    Spacer()
                                    Text(peer.message)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundColor(peer.status == "synced" ? FlomoPalette.accent(scheme) : Color(red: 0.78, green: 0.25, blue: 0.25))
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }

                    rowDivider

                    // For a second Mac joining the first Mac's note library (mirrors Navigator PairDialog)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("第二台 Mac 输入第一台 Mac 上的码，两边就接在同一份笔记库上（手机端直接输入上方 6 位码即可，无需在此处填写）。")
                            .font(.system(size: 12.5))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))

                        HStack(spacing: 10) {
                            TextField("另一台 Mac 的码", text: $remoteCodeInput)
                                .textFieldStyle(.plain)
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(FlomoPalette.canvas(scheme))
                                )
                                .onSubmit {
                                    if remoteCodeInput.filter(\.isNumber).count == 6 {
                                        vm.useOtherDeviceCode(remoteCodeInput)
                                        remoteCodeInput = ""
                                    }
                                }

                            Button("使用") {
                                vm.useOtherDeviceCode(remoteCodeInput)
                                remoteCodeInput = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(FlomoPalette.accent(scheme))
                            .disabled(remoteCodeInput.filter(\.isNumber).count != 6 || vm.isSyncing)
                        }

                        if !vm.syncMessage.isEmpty {
                            Text(vm.syncMessage)
                                .font(.system(size: 12))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                        }
                    }

                    Button("重新生成") {
                        showRegenerateConfirm = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FlomoPalette.textSecondary(scheme))
                    .padding(.top, 4)
                    .alert("重新生成配对码？", isPresented: $showRegenerateConfirm) {
                        Button("取消", role: .cancel) {}
                        Button("重新生成", role: .destructive) {
                            vm.regeneratePairCode()
                        }
                    } message: {
                        Text("重新生成后，已配对的手机和另一台 Mac 都需要重新输入新的 6 位数字。")
                    }
                }
            }

            // Collapsed fallback ONLY if a router/company Wi-Fi blocks UDP broadcast
            settingsCard {
                DisclosureGroup("无法自动发现？手动添加地址（可选）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("仅在公司网络或路由器禁用 UDP 广播时使用，正常家用 Wi-Fi 无需填写。")
                            .font(.system(size: 11.5))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                        HStack(spacing: 8) {
                            TextField("例如 192.168.5.111:8788", text: $remoteAddrInput)
                                .textFieldStyle(.roundedBorder)
                            Button("保存并同步") {
                                vm.saveManualFallbackAddr(remoteAddrInput)
                            }
                            .disabled(remoteAddrInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 12.5))
                .foregroundColor(FlomoPalette.textSecondary(scheme))
            }
        }
        .onAppear {
            vm.syncNow()
        }
    }

    private func formatSixDigit(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 6 else { return raw }
        let mid = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<mid]) \(digits[mid...])"
    }

    // MARK: - MCP & Export

    private var resolvedMCPPath: String {
        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let sibling = bundleDir.appendingPathComponent("whim-mcp").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }
        let usrLocal = "/usr/local/bin/whim-mcp"
        if FileManager.default.isExecutableFile(atPath: usrLocal) {
            return usrLocal
        }
        return sibling
    }

    private var mcpTab: some View {
        let mcpSnippet = """
        {
          "mcpServers": {
            "whim": {
              "command": "\(resolvedMCPPath)"
            }
          }
        }
        """
        return VStack(spacing: 14) {
            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("本地 MCP Server 配置")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Spacer()
                        Button(copiedMCP ? "已复制" : "复制 JSON") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(mcpSnippet, forType: .string)
                            copiedMCP = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedMCP = false }
                        }
                    }
                    Text(mcpSnippet)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(FlomoPalette.canvas(scheme)))
                }
            }

            settingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("按需导出 Markdown")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text("按日期分组导出 .md 文件与内联图片附件到「下载」目录")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                    }
                    Spacer()
                    Button("立即导出") { vm.exportMarkdown() }
                }
            }
        }
    }

    // MARK: - About & Update

    private var aboutTab: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Whim")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text("当前版本：v\(GitHubUpdater.currentVersion) · 本地优先闪念笔记")
                            .font(.system(size: 12.5))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                    }
                    Spacer()
                    Button("GitHub 仓库") {
                        if let url = URL(string: "https://github.com/\(GitHubUpdater.repo)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(FlomoPalette.tagText(scheme))
                }

                rowDivider

                Text(updater.status)
                    .font(.system(size: 12.5))
                    .foregroundColor(FlomoPalette.textSecondary(scheme))

                if let notes = updater.latestRelease?.body, !notes.isEmpty, updater.hasUpdate {
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(FlomoPalette.canvas(scheme)))
                }

                HStack(spacing: 10) {
                    Button(updater.checking ? "检查中..." : "检查更新") {
                        updater.checkForUpdates()
                    }
                    .disabled(updater.checking || updater.downloading)

                    if updater.hasUpdate {
                        Button(updater.downloading ? "下载安装中..." : "一键更新并重启") {
                            updater.downloadAndInstall()
                        }
                        .disabled(updater.downloading)
                        .buttonStyle(.borderedProminent)
                        .tint(FlomoPalette.accent(scheme))
                    }
                }
            }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FlomoPalette.card(scheme))
            )
    }

    private func shortcutRow(_ title: String, keys: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13.5))
                .foregroundColor(FlomoPalette.textPrimary(scheme))
            Spacer()
            Text(keys)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(FlomoPalette.accent(scheme))
        }
        .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(FlomoPalette.border(scheme))
            .frame(height: 1)
    }
}
