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
    case review = "每日提醒"
    case shortcuts = "快捷键"
    case sync = "局域网同步"
    case mcp = "MCP / 导出"
    case about = "关于与更新"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .review: return "bell.badge"
        case .shortcuts: return "command"
        case .sync: return "arrow.triangle.2.circlepath"
        case .mcp: return "chevron.left.forwardslash.chevron.right"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "外观主题、本地数据空间与维护工具"
        case .review: return "设置多个定时复盘与总结闹钟，不错过每一次沉淀"
        case .shortcuts: return "全局速记与高效编辑快捷键参考"
        case .sync: return "同 Wi-Fi 下零配置 P2P 双向加密同步"
        case .mcp: return "连接 AI 助手或按需导出标准 Markdown 文件"
        case .about: return "版本信息与 GitHub Release 在线更新"
        }
    }

    static let preferenceGroup: [SettingsSection] = [.general, .review, .shortcuts]
    static let dataGroup: [SettingsSection] = [.sync, .mcp, .about]
}

struct SettingsModalView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: WhimStoreVM
    @Binding var themeModeRaw: String
    var initialSection: SettingsSection = .general
    let onApplyTheme: (AppThemeMode) -> Void
    let onClose: () -> Void

    @State private var activeSection: SettingsSection = .general
    @State private var editingReminderId: String? = nil
    @State private var remoteAddrInput: String = ""
    @State private var remoteCodeInput: String = ""
    @State private var pairingPeerId: String? = nil
    @State private var inlinePairCode: String = ""
    @State private var showManualAddr: Bool = false
    @State private var copiedLocalCode: Bool = false
    @State private var showRegenerateConfirm: Bool = false
    @State private var copiedMCP: Bool = false
    @State private var storageTotalBytes: Int64 = 0
    @State private var storageDbBytes: Int64 = 0
    @State private var storageBlobsBytes: Int64 = 0
    @State private var storageBlobCount: Int = 0
    @State private var storageOrphanCount: Int = 0
    @State private var storageOrphanBytes: Int64 = 0
    @State private var storageCleanupMsg: String = ""
    @State private var isCleaningStorage: Bool = false
    @State private var storageLoaded: Bool = false
    @ObservedObject private var updater = GitHubUpdater.shared

    private var themeMode: AppThemeMode {
        AppThemeMode(rawValue: themeModeRaw) ?? .system
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(FlomoPalette.accent(scheme))
                            .frame(width: 24, height: 24)
                        Image(systemName: "sparkle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("偏好设置")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text("Whim · 本地优先")
                            .font(.system(size: 10.5))
                            .foregroundColor(FlomoPalette.textMuted(scheme))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    sidebarGroupLabel("偏好")
                    ForEach(SettingsSection.preferenceGroup) { sec in
                        SettingsSidebarRow(
                            section: sec,
                            active: activeSection == sec,
                            badgeText: sec == .review && vm.hasEnabledReminders ? "\(vm.enabledReminders.count)" : nil,
                            showRedDot: false
                        ) {
                            withAnimation(.easeOut(duration: 0.14)) {
                                activeSection = sec
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    sidebarGroupLabel("连接与数据")
                    ForEach(SettingsSection.dataGroup) { sec in
                        SettingsSidebarRow(
                            section: sec,
                            active: activeSection == sec,
                            badgeText: nil,
                            showRedDot: sec == .about && updater.hasUpdate
                        ) {
                            withAnimation(.easeOut(duration: 0.14)) {
                                activeSection = sec
                            }
                        }
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.syncHealth.connected ? Color(hex: 0x34D399) : FlomoPalette.textMuted(scheme))
                        .frame(width: 6, height: 6)
                    Text("v\(GitHubUpdater.currentVersion)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                }
                .padding(.horizontal, 10)
            }
            .padding(16)
            .frame(width: 208)
            .background(FlomoPalette.sidebar(scheme))

            // Hairline vertical divider
            Rectangle()
                .fill(FlomoPalette.border(scheme))
                .frame(width: 1)

            // Right Detail Area
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeSection.rawValue)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text(activeSection.subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                            .frame(width: 28, height: 28)
                            .whimClickable(cornerRadius: 7, hoverFill: true)
                    }
                    .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
                    .help("关闭设置 (Esc)")
                }
                .padding(.horizontal, 26)
                .padding(.top, 22)
                .padding(.bottom, 16)

                Rectangle()
                    .fill(FlomoPalette.border(scheme))
                    .frame(height: 1)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        switch activeSection {
                        case .general: generalTab
                        case .review: reviewTab
                        case .shortcuts: shortcutsTab
                        case .sync: syncTab
                        case .mcp: mcpTab
                        case .about: aboutTab
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlomoPalette.canvas(scheme))
        }
        .frame(width: 740, height: 560)
        .preferredColorScheme(themeMode.colorScheme)
        .onAppear {
            activeSection = initialSection
            vm.refreshSyncState()
            refreshStorageUsage()
        }
    }

    private func sidebarGroupLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(FlomoPalette.textMuted(scheme))
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(spacing: 16) {
            // Visual Theme Selector
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("外观主题")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text("选择适合你的阅读与记录氛围，支持自动跟随 macOS 外观")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                    }

                    HStack(spacing: 12) {
                        ForEach(AppThemeMode.allCases) { mode in
                            ThemePreviewCard(
                                mode: mode,
                                selected: themeMode == mode
                            ) {
                                themeModeRaw = mode.rawValue
                                onApplyTheme(mode)
                            }
                        }
                    }
                }
            }

            // Visual Storage Card with Segmented Bar
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本地存储空间")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                            Text(storageLoaded ? "所有笔记与图片均保存在本机应用目录" : "正在统计本地存储...")
                                .font(.system(size: 12))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                        }
                        Spacer()
                        Text(storageLoaded ? formatBytes(storageTotalBytes) : "--")
                            .font(.system(size: 20, weight: .bold).monospacedDigit())
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                    }

                    if storageLoaded {
                        storageBarView

                        HStack(spacing: 16) {
                            storageLegendDot(color: FlomoPalette.accent(scheme), label: "数据库", value: formatBytes(storageDbBytes))
                            storageLegendDot(color: FlomoPalette.tagText(scheme), label: "图片 (\(storageBlobCount)张)", value: formatBytes(max(0, storageBlobsBytes - storageOrphanBytes)))
                            if storageOrphanCount > 0 {
                                storageLegendDot(color: FlomoPalette.warning(scheme), label: "冗余 (\(storageOrphanCount)张)", value: formatBytes(storageOrphanBytes))
                            }
                            Spacer()
                        }
                    }

                    rowDivider

                    HStack(spacing: 10) {
                        WhimSecondaryButton(
                            title: isCleaningStorage ? "清理中..." : "清理冗余图片",
                            icon: "sparkles",
                            compact: true
                        ) {
                            cleanupOrphanStorage()
                        }
                        .disabled(isCleaningStorage)

                        WhimSecondaryButton(title: "在访达中打开", icon: "folder", compact: true) {
                            NSWorkspace.shared.open(whimDataDirectory())
                        }

                        WhimSecondaryButton(title: "刷新统计", icon: "arrow.clockwise", compact: true) {
                            refreshStorageUsage()
                        }
                        Spacer()
                    }

                    if !storageCleanupMsg.isEmpty {
                        Text(storageCleanupMsg)
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.accent(scheme))
                    }
                }
            }

            // Daily Automatic Local Backup Card
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("每日自动备份")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                            Text("启动时自动创建 WAL 安全快照，滚动保留最近 7 天")
                                .font(.system(size: 12))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                        }
                        Spacer()
                        Text("已存 \(vm.backups.count) 份")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundColor(FlomoPalette.accent(scheme))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(FlomoPalette.accentSoft(scheme)))
                    }

                    if let latest = vm.backups.first {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 12))
                                .foregroundColor(FlomoPalette.accent(scheme))
                            Text("最近备份：\(latest.name)（\(formatBytes(latest.sizeBytes))）")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                        }
                    }

                    HStack(spacing: 10) {
                        WhimSecondaryButton(
                            title: vm.isBackingUp ? "备份中..." : "立即备份",
                            icon: "externaldrive.badge.plus",
                            compact: true
                        ) {
                            vm.runBackup(force: true)
                        }
                        .disabled(vm.isBackingUp)

                        WhimSecondaryButton(title: "打开备份目录", icon: "folder", compact: true) {
                            let dir = whimDataDirectory().appendingPathComponent("backups", isDirectory: true)
                            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(dir)
                        }
                        Spacer()
                    }

                    if !vm.backupStatusMsg.isEmpty {
                        Text(vm.backupStatusMsg)
                            .font(.system(size: 11.5))
                            .foregroundColor(FlomoPalette.accent(scheme))
                    }
                }
            }

            // Dev Sample Data
            settingsCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("示例数据")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text("快速注入或一键清除带 #示例 标签的测试闪念")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                    }
                    Spacer()
                    WhimSecondaryButton(title: "注入示例", compact: true) {
                        vm.seedSampleNotes()
                        refreshStorageUsage()
                    }
                    WhimSecondaryButton(title: "清除示例", destructive: true, compact: true) {
                        vm.clearSampleNotes()
                        refreshStorageUsage()
                    }
                }
            }
        }
    }

    private var storageBarView: some View {
        let total = max(Double(storageTotalBytes), 1.0)
        let dbRatio = min(1.0, Double(storageDbBytes) / total)
        let activeBlobBytes = max(0, storageBlobsBytes - storageOrphanBytes)
        let blobRatio = min(1.0 - dbRatio, Double(activeBlobBytes) / total)
        let orphanRatio = min(1.0 - dbRatio - blobRatio, Double(storageOrphanBytes) / total)

        return GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 2) {
                if storageDbBytes > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(FlomoPalette.accent(scheme))
                        .frame(width: max(6, w * dbRatio))
                }
                if activeBlobBytes > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(FlomoPalette.tagText(scheme))
                        .frame(width: max(6, w * blobRatio))
                }
                if storageOrphanBytes > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(FlomoPalette.warning(scheme))
                        .frame(width: max(6, w * orphanRatio))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(FlomoPalette.canvas(scheme))
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 8)
    }

    private func storageLegendDot(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundColor(FlomoPalette.textSecondary(scheme))
            Text(value)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundColor(FlomoPalette.textPrimary(scheme))
        }
    }

    private func whimDataDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Whim", isDirectory: true)
    }

    private func refreshStorageUsage() {
        let dir = whimDataDirectory()
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var total: Int64 = 0
            var db: Int64 = 0
            var blobs: Int64 = 0
            var blobCnt: Int = 0
            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          vals.isRegularFile == true,
                          let sz = vals.fileSize else { continue }
                    let size64 = Int64(sz)
                    total += size64
                    if url.path.contains("/blobs/") {
                        blobs += size64
                        blobCnt += 1
                    } else if url.lastPathComponent.hasPrefix("whim.sqlite3") {
                        db += size64
                    }
                }
            }
            let dry = try? CoreBridge.shared.cleanupOrphanBlobs(minAgeSec: 0, dryRun: true)
            DispatchQueue.main.async {
                storageTotalBytes = total
                storageDbBytes = db
                storageBlobsBytes = blobs
                storageBlobCount = blobCnt
                storageOrphanCount = dry?.removedFiles ?? 0
                storageOrphanBytes = dry?.freedBytes ?? 0
                storageLoaded = true
            }
        }
    }

    private func cleanupOrphanStorage() {
        isCleaningStorage = true
        storageCleanupMsg = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let res = try? CoreBridge.shared.cleanupOrphanBlobs(minAgeSec: 0, dryRun: false)
            DispatchQueue.main.async {
                isCleaningStorage = false
                if let res {
                    storageCleanupMsg = res.removedFiles > 0
                        ? "已清理 \(res.removedFiles) 张冗余图片，释放 \(formatBytes(res.freedBytes))"
                        : "没有发现未引用的冗余图片，已整理数据库缓存"
                } else {
                    storageCleanupMsg = "清理失败，请重试"
                }
                refreshStorageUsage()
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    // MARK: - Multi-Reminder Clocks (每日提醒)

    private var reviewTab: some View {
        let enabledCount = vm.enabledReminders.count
        let hasMorning = vm.reviewReminders.contains { (5..<12).contains($0.hour) }
        let hasEvening = vm.reviewReminders.contains { $0.hour >= 18 || $0.hour < 5 }

        return VStack(spacing: 14) {
            // Top Summary & Add Action Bar
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(enabledCount > 0 ? FlomoPalette.accent(scheme) : FlomoPalette.textMuted(scheme))
                        .frame(width: 8, height: 8)
                    Text(enabledCount > 0 ? "已开启 \(enabledCount) 个定时提醒" : "当前未开启任何提醒")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(FlomoPalette.textPrimary(scheme))
                }
                Spacer()
                WhimPrimaryButton(title: "添加提醒", icon: "plus", compact: true) {
                    let defaultHour = hasEvening && !hasMorning ? 8 : (hasMorning && !hasEvening ? 21 : 12)
                    let defaultLabel = defaultHour == 8 ? "晨间复盘" : (defaultHour == 21 ? "晚间总结" : "午后回顾")
                    let created = vm.addReminder(label: defaultLabel, hour: defaultHour, minute: 30)
                    withAnimation(.easeOut(duration: 0.18)) {
                        editingReminderId = created.id
                    }
                }
            }
            .padding(.horizontal, 2)

            if vm.reviewReminders.isEmpty {
                settingsCard {
                    VStack(spacing: 12) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 26))
                            .foregroundColor(FlomoPalette.textMuted(scheme))
                        Text("还没有设置提醒时钟")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text("可以为早晚分别添加提醒，例如晚上总结今日收获，次日清晨复盘昨日思路。")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                            .multilineTextAlignment(.center)
                        HStack(spacing: 10) {
                            WhimSecondaryButton(title: "08:30 晨间复盘", icon: "sunrise.fill", compact: true) {
                                _ = vm.addReminder(label: "晨间复盘", hour: 8, minute: 30)
                            }
                            WhimSecondaryButton(title: "21:30 晚间总结", icon: "moon.stars.fill", compact: true) {
                                _ = vm.addReminder(label: "晚间总结", hour: 21, minute: 30)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(vm.reviewReminders) { reminder in
                        ReminderClockCard(
                            reminder: reminder,
                            isExpanded: editingReminderId == reminder.id,
                            onToggleExpand: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    editingReminderId = editingReminderId == reminder.id ? nil : reminder.id
                                }
                            },
                            onToggleEnabled: {
                                vm.toggleReminder(id: reminder.id)
                            },
                            onUpdate: { updated in
                                vm.updateReminder(updated)
                            },
                            onDelete: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    if editingReminderId == reminder.id { editingReminderId = nil }
                                    vm.deleteReminder(id: reminder.id)
                                }
                            }
                        )
                    }
                }

                // Helpful quick-add suggestion when user only has morning or only evening
                if vm.reviewReminders.count < 2 {
                    HStack(spacing: 10) {
                        if !hasMorning {
                            quickAddPresetCard(icon: "sunrise.fill", title: "添加晨间复盘", time: "08:30") {
                                let created = vm.addReminder(label: "晨间复盘", hour: 8, minute: 30)
                                withAnimation(.easeOut(duration: 0.18)) { editingReminderId = created.id }
                            }
                        }
                        if !hasEvening {
                            quickAddPresetCard(icon: "moon.stars.fill", title: "添加晚间总结", time: "21:30") {
                                let created = vm.addReminder(label: "晚间总结", hour: 21, minute: 30)
                                withAnimation(.easeOut(duration: 0.18)) { editingReminderId = created.id }
                            }
                        }
                    }
                }
            }

            // Notification Utilities Card
            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        WhimSecondaryButton(title: "发送测试通知", icon: "bell.and.waves.left.and.right", compact: true) {
                            vm.sendTestReviewNotification()
                        }
                        WhimSecondaryButton(title: "系统通知设置", icon: "gearshape", compact: true) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Spacer()
                    }

                    if !vm.reviewNotificationStatus.isEmpty {
                        Text(vm.reviewNotificationStatus)
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.accent(scheme))
                    }

                    Text("提醒由 macOS 系统通知中心托管，App 退出或在后台均会按时送达；点击通知直达「每日回顾」，展开可选「30 分钟后再提醒」。")
                        .font(.system(size: 11.5))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                }
            }
        }
    }

    private func quickAddPresetCard(icon: String, title: String, time: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(FlomoPalette.accent(scheme))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(FlomoPalette.textPrimary(scheme))
                Spacer()
                Text(time)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(FlomoPalette.textSecondary(scheme))
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(FlomoPalette.accent(scheme))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FlomoPalette.card(scheme).opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(FlomoPalette.borderStrong(scheme))
            )
            .whimClickable(cornerRadius: 10, hoverFill: true)
        }
        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 10))
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        settingsCard {
            VStack(spacing: 0) {
                shortcutRow("新建悬浮输入窗（全局）", keys: ["⌘", "⇧", "J"])
                rowDivider
                shortcutRow("发布笔记", keys: ["⌘", "↩"])
                rowDivider
                shortcutRow("换行", keys: ["↩"])
                rowDivider
                shortcutRow("光标处粘贴内联图片", keys: ["⌘", "V"])
                rowDivider
                shortcutRow("搜索笔记与标签", keys: ["⌘", "K"])
                rowDivider
                shortcutRow("打开偏好设置", keys: ["⌘", ","])
                rowDivider
                shortcutRow("关闭未固定浮窗", keys: ["Esc"])
            }
        }
    }

    // MARK: - LAN Sync (Route B: Per-Device Code + Multi-Device Sync + Bidirectional Unpair)

    private var syncTab: some View {
        let digits = Array(vm.pairCode.filter(\.isNumber))
        let liveById = Dictionary(uniqueKeysWithValues: (vm.syncHealth.peers ?? []).map { ($0.peerId, $0) })
        let pairedIdSet = Set(vm.pairedPeers.map(\.peerId))
        let visibleDiscovered = vm.discoveredPeers.filter { !pairedIdSet.contains($0.peerId) && !vm.ignoredPeerIDs.contains($0.peerId) }

        return VStack(spacing: 16) {
            // Card 1: This Mac's Own Independent 6-Digit Code
            settingsCard {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本机专属配对码")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                            Text("每台电脑拥有独立配对码；连接其他 Mac 时不会改变此码")
                                .font(.system(size: 11.5))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                        }
                        Spacer()
                        WhimSecondaryButton(title: "重新生成", icon: "arrow.2.squarepath", compact: true) {
                            showRegenerateConfirm = true
                        }
                        .alert("重新生成本机配对码？", isPresented: $showRegenerateConfirm) {
                            Button("取消", role: .cancel) {}
                            Button("重新生成", role: .destructive) {
                                vm.regeneratePairCode()
                            }
                        } message: {
                            Text("仅影响连接到本机的其他设备，它们需要重新输入新的 6 位数字；本机已配对的其他 Mac 不受影响。")
                        }
                    }

                    HStack(spacing: 16) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(vm.pairCode, forType: .string)
                            copiedLocalCode = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copiedLocalCode = false }
                        } label: {
                            VStack(spacing: 8) {
                                HStack(spacing: 6) {
                                    ForEach(0..<6, id: \.self) { idx in
                                        let ch = idx < digits.count ? String(digits[idx]) : "-"
                                        Text(ch)
                                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                                            .frame(width: 34, height: 44)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .fill(FlomoPalette.canvas(scheme))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(
                                                        copiedLocalCode ? FlomoPalette.accent(scheme) : FlomoPalette.borderStrong(scheme),
                                                        lineWidth: copiedLocalCode ? 1.5 : 1
                                                    )
                                            )
                                        if idx == 2 {
                                            Spacer().frame(width: 4)
                                        }
                                    }
                                }

                                HStack(spacing: 5) {
                                    Image(systemName: copiedLocalCode ? "checkmark.circle.fill" : "doc.on.doc")
                                        .font(.system(size: 11.5))
                                    Text(copiedLocalCode ? "已复制到剪贴板" : "点击复制配对码")
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                                .foregroundColor(copiedLocalCode ? FlomoPalette.accent(scheme) : FlomoPalette.tagText(scheme))

                                if !vm.localAddr.isEmpty {
                                    Text(vm.localAddr)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundColor(FlomoPalette.textMuted(scheme))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .whimClickable(cornerRadius: 10, hoverFill: true)
                        }
                        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 10))

                        if !vm.localAddr.isEmpty && digits.count == 6,
                           let qrImg = QRCodeHelper.generate(from: "whim://pair?addr=\(vm.localAddr)&code=\(vm.pairCode)", size: 160) {
                            VStack(spacing: 5) {
                                Image(nsImage: qrImg)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 96, height: 96)
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
                                Text("手机扫码配对")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(FlomoPalette.textMuted(scheme))
                            }
                        }
                    }
                }
            }

            // Card 2: Paired Devices (Concurrent Multi-Device Sync + Bidirectional Forget)
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        HStack(spacing: 6) {
                            Text("已配对设备")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                            if !vm.pairedPeers.isEmpty {
                                Text("\(vm.pairedPeers.count)")
                                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .foregroundColor(FlomoPalette.accent(scheme))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(FlomoPalette.accentSoft(scheme)))
                            }
                        }
                        Spacer()
                        WhimSecondaryButton(
                            title: vm.isSyncing ? "同步中..." : "立即同步",
                            icon: "arrow.triangle.2.circlepath",
                            compact: true
                        ) {
                            vm.syncNow()
                        }
                        .disabled(vm.isSyncing)
                    }

                    if vm.pairedPeers.isEmpty {
                        Text("尚未配对其他设备。在下方「局域网发现」中点击配对并输入对方的 6 位码，或在手机端输入上方本机码。")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textMuted(scheme))
                            .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(vm.pairedPeers) { peer in
                                let live = liveById[peer.peerId]
                                let isOnline = live?.online ?? false
                                let isWrongCode = live?.status == "wrong_code"
                                let dotColor: Color = isOnline ? Color(hex: 0x34D399) : (isWrongCode ? FlomoPalette.warning(scheme) : FlomoPalette.textMuted(scheme))
                                let statusText: String = {
                                    if let live, let msg = live.message, !msg.isEmpty { return msg }
                                    return isOnline ? "在线" : "离线"
                                }()

                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(dotColor)
                                        .frame(width: 8, height: 8)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.displayName.isEmpty ? "已配对设备" : peer.displayName)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                                        HStack(spacing: 6) {
                                            if !peer.lastAddr.isEmpty {
                                                Text(peer.lastAddr)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundColor(FlomoPalette.textMuted(scheme))
                                            }
                                            Text(statusText)
                                                .font(.system(size: 11, weight: isOnline ? .medium : .regular))
                                                .foregroundColor(isOnline ? FlomoPalette.accent(scheme) : (isWrongCode ? FlomoPalette.warning(scheme) : FlomoPalette.textSecondary(scheme)))
                                        }
                                    }

                                    Spacer()

                                    WhimSecondaryButton(title: "忘记", destructive: true, compact: true) {
                                        vm.forgetPeer(peerId: peer.peerId, displayName: peer.displayName)
                                    }
                                    .help("断开连接并通知对方停止自动重连")
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(FlomoPalette.canvas(scheme))
                                )
                            }
                        }
                    }
                }
            }

            // Card 3: Nearby Discovered LAN Devices (Pair with Remote Code or Ignore)
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("局域网发现")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Spacer()
                        WhimSecondaryButton(
                            title: vm.isScanningLAN ? "扫描中..." : "重新扫描",
                            icon: "dot.radiowaves.left.and.right",
                            compact: true
                        ) {
                            vm.scanLANPeers()
                        }
                        .disabled(vm.isScanningLAN)
                    }

                    if visibleDiscovered.isEmpty {
                        Text(vm.isScanningLAN ? "正在扫描同一 Wi-Fi 下的 Whim 设备..." : "暂未发现新的未配对设备")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textMuted(scheme))
                            .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(visibleDiscovered) { peer in
                                let isExpandingPair = pairingPeerId == peer.peerId
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "laptopcomputer")
                                            .font(.system(size: 13))
                                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(peer.displayName.isEmpty ? peer.addr : peer.displayName)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                                            Text(peer.addr)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(FlomoPalette.textMuted(scheme))
                                        }
                                        Spacer()
                                        WhimSecondaryButton(title: "忽略", compact: true) {
                                            if pairingPeerId == peer.peerId { pairingPeerId = nil }
                                            vm.ignoreDiscoveredPeer(peerId: peer.peerId)
                                        }
                                        WhimPrimaryButton(title: isExpandingPair ? "收起" : "配对", compact: true) {
                                            withAnimation(.easeOut(duration: 0.16)) {
                                                if isExpandingPair {
                                                    pairingPeerId = nil
                                                } else {
                                                    pairingPeerId = peer.peerId
                                                    inlinePairCode = ""
                                                }
                                            }
                                        }
                                    }

                                    if isExpandingPair {
                                        HStack(spacing: 8) {
                                            TextField("输入对方的 6 位配对码", text: $inlinePairCode)
                                                .textFieldStyle(.plain)
                                                .font(.system(size: 13.5, design: .monospaced))
                                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 7)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                        .fill(FlomoPalette.card(scheme))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                        .stroke(FlomoPalette.accent(scheme).opacity(0.6), lineWidth: 1)
                                                )
                                                .onSubmit {
                                                    if inlinePairCode.filter(\.isNumber).count == 6 {
                                                        vm.pairWithDevice(addr: peer.addr, remoteCode: inlinePairCode) { ok in
                                                            if ok {
                                                                pairingPeerId = nil
                                                                inlinePairCode = ""
                                                            }
                                                        }
                                                    }
                                                }

                                            WhimPrimaryButton(title: vm.isPairingDevice ? "连接中..." : "确认配对", compact: true) {
                                                vm.pairWithDevice(addr: peer.addr, remoteCode: inlinePairCode) { ok in
                                                    if ok {
                                                        pairingPeerId = nil
                                                        inlinePairCode = ""
                                                    }
                                                }
                                            }
                                            .disabled(inlinePairCode.filter(\.isNumber).count != 6 || vm.isPairingDevice)
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(FlomoPalette.canvas(scheme))
                                )
                            }
                        }
                    }

                    if !vm.ignoredPeerIDs.isEmpty {
                        HStack {
                            Text("已忽略 \(vm.ignoredPeerIDs.count) 台局域网设备")
                                .font(.system(size: 11.5))
                                .foregroundColor(FlomoPalette.textMuted(scheme))
                            Spacer()
                            Button {
                                vm.restoreIgnoredPeers()
                            } label: {
                                Text("恢复显示")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(FlomoPalette.tagText(scheme))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .whimClickable(cornerRadius: 6, hoverFill: true)
                            }
                            .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
                        }
                    }

                    if !vm.syncMessage.isEmpty {
                        Text(vm.syncMessage)
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.accent(scheme))
                    }
                }
            }

            // Card 4: Collapsible Manual IP:Port + Remote Code Pairing Fallback
            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showManualAddr.toggle()
                        }
                    } label: {
                        HStack {
                            Image(systemName: showManualAddr ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(FlomoPalette.textMuted(scheme))
                                .frame(width: 14)
                            Text("无法自动发现？手动输入地址与对方配对码")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                            Spacer()
                        }
                        .padding(.vertical, 2)
                        .whimClickable(cornerRadius: 6, hoverFill: false)
                    }
                    .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6, pressScale: 1.0))

                    if showManualAddr {
                        Text("仅在公司网络或路由器禁用 UDP 广播时使用，正常家用 Wi-Fi 无需填写。")
                            .font(.system(size: 11.5))
                            .foregroundColor(FlomoPalette.textMuted(scheme))
                        HStack(spacing: 8) {
                            TextField("IP:端口（如 192.168.5.111:8788）", text: $remoteAddrInput)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(FlomoPalette.canvas(scheme))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(FlomoPalette.border(scheme), lineWidth: 1)
                                )
                            TextField("对方 6 位码", text: $remoteCodeInput)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                                .frame(width: 108)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(FlomoPalette.canvas(scheme))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(FlomoPalette.border(scheme), lineWidth: 1)
                                )
                            WhimPrimaryButton(title: vm.isPairingDevice ? "连接中..." : "配对", compact: true) {
                                vm.pairWithDevice(addr: remoteAddrInput, remoteCode: remoteCodeInput) { ok in
                                    if ok {
                                        remoteAddrInput = ""
                                        remoteCodeInput = ""
                                    }
                                }
                            }
                            .disabled(remoteAddrInput.trimmingCharacters(in: .whitespaces).isEmpty || remoteCodeInput.filter(\.isNumber).count != 6 || vm.isPairingDevice)
                        }
                    }
                }
            }
        }
        .onAppear {
            vm.refreshSyncState()
            vm.scanLANPeers()
            vm.refreshSyncHealth(activeProbe: true)
        }
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
        return VStack(spacing: 16) {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本地 MCP Server 配置")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                            Text("粘贴到 Claude Desktop / Cursor 的 MCP 配置文件即可直接检索你的笔记")
                                .font(.system(size: 12))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                        }
                        Spacer()
                        WhimSecondaryButton(
                            title: copiedMCP ? "已复制" : "复制 JSON",
                            icon: copiedMCP ? "checkmark" : "doc.on.doc",
                            compact: true
                        ) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(mcpSnippet, forType: .string)
                            copiedMCP = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedMCP = false }
                        }
                    }

                    Text(mcpSnippet)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(FlomoPalette.textPrimary(scheme).opacity(0.88))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(FlomoPalette.canvas(scheme))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(FlomoPalette.border(scheme), lineWidth: 1)
                        )
                }
            }

            settingsCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("按需导出 Markdown")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text("按日期分组导出 .md 文件与内联图片附件到「下载」目录")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                    }
                    Spacer()
                    WhimPrimaryButton(title: "立即导出", icon: "square.and.arrow.up", compact: true) {
                        vm.exportMarkdown()
                    }
                }
            }
        }
    }

    // MARK: - About & Update

    private var aboutTab: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(FlomoPalette.accent(scheme))
                            .frame(width: 44, height: 44)
                        Image(systemName: "sparkle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Whim")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                            Text("v\(GitHubUpdater.currentVersion)")
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundColor(FlomoPalette.accent(scheme))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(FlomoPalette.accentSoft(scheme))
                                )
                        }
                        Text("本地优先闪念笔记 · SQLite + 局域网 P2P 双向同步")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                    }
                    Spacer()
                    WhimSecondaryButton(title: "GitHub", icon: "arrow.up.right", compact: true) {
                        if let url = URL(string: "https://github.com/\(GitHubUpdater.repo)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                rowDivider

                Text(updater.status)
                    .font(.system(size: 12.5))
                    .foregroundColor(updater.hasUpdate ? FlomoPalette.accent(scheme) : FlomoPalette.textSecondary(scheme))

                if updater.downloading {
                    ProgressView(value: updater.downloadProgress)
                        .tint(FlomoPalette.accent(scheme))
                }

                if let notes = updater.latestRelease?.body, !notes.isEmpty, updater.hasUpdate {
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(FlomoPalette.canvas(scheme))
                    )
                }

                HStack(spacing: 10) {
                    WhimSecondaryButton(
                        title: updater.checking ? "检查中..." : "检查更新",
                        icon: "arrow.clockwise",
                        compact: true
                    ) {
                        updater.checkForUpdates()
                    }
                    .disabled(updater.checking || updater.downloading)

                    if updater.hasUpdate {
                        WhimPrimaryButton(
                            title: updater.downloading ? "下载安装中..." : "一键更新并重启",
                            icon: "arrow.down.circle",
                            compact: true
                        ) {
                            updater.downloadAndInstall()
                        }
                        .disabled(updater.downloading)

                        if !updater.downloading {
                            WhimSecondaryButton(title: "跳过此版本", compact: true) {
                                updater.skipCurrentRelease()
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Shared Helpers

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FlomoPalette.card(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(FlomoPalette.border(scheme), lineWidth: 1)
            )
    }

    private func shortcutRow(_ title: String, keys: [String]) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(FlomoPalette.textPrimary(scheme))
            Spacer()
            HStack(spacing: 5) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(FlomoPalette.textPrimary(scheme))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .frame(minWidth: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(FlomoPalette.canvas(scheme))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(FlomoPalette.borderStrong(scheme), lineWidth: 1)
                        )
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(FlomoPalette.border(scheme))
            .frame(height: 1)
    }
}

// MARK: - Settings Subcomponents (Full-Area Hit-Tested)

private struct SettingsSidebarRow: View {
    @Environment(\.colorScheme) private var scheme
    let section: SettingsSection
    let active: Bool
    let badgeText: String?
    let showRedDot: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? .white : FlomoPalette.textSecondary(scheme))
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13.5, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? .white : FlomoPalette.textPrimary(scheme))
                Spacer()
                if let badgeText, !badgeText.isEmpty {
                    Text(badgeText)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(active ? .white : FlomoPalette.accent(scheme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(active ? Color.white.opacity(0.22) : FlomoPalette.accentSoft(scheme))
                        )
                }
                if showRedDot {
                    Circle()
                        .fill(Color(hex: 0xEF4444))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        active
                            ? FlomoPalette.accent(scheme)
                            : (isHovered ? FlomoPalette.hoverFill(scheme) : .clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 8, pressScale: 0.99))
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if isHovered { isHovered = false; NSCursor.pop() }
        }
    }
}

private struct ThemePreviewCard: View {
    @Environment(\.colorScheme) private var scheme
    let mode: AppThemeMode
    let selected: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Mini Window Preview
                ZStack {
                    switch mode {
                    case .light:
                        miniWindowMock(isDark: false)
                    case .dark:
                        miniWindowMock(isDark: true)
                    case .system:
                        HStack(spacing: 0) {
                            miniWindowMock(isDark: false)
                                .frame(maxWidth: .infinity)
                                .clipped()
                            miniWindowMock(isDark: true)
                                .frame(maxWidth: .infinity)
                                .clipped()
                        }
                    }
                }
                .frame(height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(FlomoPalette.border(scheme), lineWidth: 1)
                )

                HStack(spacing: 5) {
                    Text(mode.label)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? FlomoPalette.accent(scheme) : FlomoPalette.textPrimary(scheme))
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.accent(scheme))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        selected
                            ? FlomoPalette.accentSoft(scheme)
                            : (isHovered ? FlomoPalette.hoverFill(scheme) : FlomoPalette.canvas(scheme))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selected ? FlomoPalette.accent(scheme) : FlomoPalette.border(scheme),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 10))
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if isHovered { isHovered = false; NSCursor.pop() }
        }
    }

    private func miniWindowMock(isDark: Bool) -> some View {
        let bg = isDark ? Color(hex: 0x141414) : Color(hex: 0xF3F3F3)
        let card = isDark ? Color(hex: 0x222222) : Color.white
        let line = isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.15)
        return HStack(spacing: 5) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(FlomoPalette.accent(scheme)).frame(height: 7)
                RoundedRectangle(cornerRadius: 2).fill(line).frame(height: 5)
                RoundedRectangle(cornerRadius: 2).fill(line).frame(height: 5)
                Spacer()
            }
            .frame(width: 24)
            .padding(.top, 8)
            .padding(.leading, 6)

            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 4).fill(card).frame(height: 20)
                RoundedRectangle(cornerRadius: 4).fill(card).frame(height: 20)
                Spacer()
            }
            .padding(.top, 8)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bg)
    }
}

private struct ReminderClockCard: View {
    @Environment(\.colorScheme) private var scheme
    let reminder: ReviewReminder
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onToggleEnabled: () -> Void
    let onUpdate: (ReviewReminder) -> Void
    let onDelete: () -> Void

    @State private var isHeaderHovered: Bool = false
    @State private var draftLabel: String = ""
    @State private var draftHour: Int = 21
    @State private var draftMinute: Int = 30
    @State private var draftWeekdays: Set<Int> = ReviewReminder.allWeekdays

    private let weekdayItems: [(Int, String)] = [(2, "一"), (3, "二"), (4, "三"), (5, "四"), (6, "五"), (7, "六"), (1, "日")]
    private let labelPresets: [String] = ["晨间复盘", "午后回顾", "晚间总结", "睡前清空"]

    private var iconTint: Color {
        switch reminder.hour {
        case 5..<11: return Color(hex: 0xE5A03D)
        case 11..<18: return Color(hex: 0x5B9BFF)
        default: return FlomoPalette.accent(scheme)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card Header Row (full-area clickable on the left to expand/collapse)
            HStack(spacing: 12) {
                Button(action: onToggleExpand) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(reminder.enabled ? iconTint.opacity(0.16) : FlomoPalette.canvas(scheme))
                                .frame(width: 38, height: 38)
                            Image(systemName: reminder.timeIcon)
                                .font(.system(size: 16))
                                .foregroundColor(reminder.enabled ? iconTint : FlomoPalette.textMuted(scheme))
                        }

                        Text(reminder.formattedTime)
                            .font(.system(size: 23, weight: .semibold, design: .monospaced))
                            .foregroundColor(reminder.enabled ? FlomoPalette.textPrimary(scheme) : FlomoPalette.textMuted(scheme))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(reminder.displayTitle)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(reminder.enabled ? FlomoPalette.textPrimary(scheme) : FlomoPalette.textSecondary(scheme))
                            Text(reminder.repeatSummary)
                                .font(.system(size: 11.5))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                        }

                        Spacer()

                        HStack(spacing: 4) {
                            Text(isExpanded ? "收起" : "编辑")
                                .font(.system(size: 11.5, weight: .medium))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(isHeaderHovered || isExpanded ? FlomoPalette.accent(scheme) : FlomoPalette.textMuted(scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isHeaderHovered ? FlomoPalette.hoverFill(scheme) : .clear)
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 8, pressScale: 0.995))
                .onHover { hovering in
                    isHeaderHovered = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .onDisappear {
                    if isHeaderHovered { isHeaderHovered = false; NSCursor.pop() }
                }

                Toggle("", isOn: Binding(
                    get: { reminder.enabled },
                    set: { _ in onToggleEnabled() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(FlomoPalette.accent(scheme))
            }
            .padding(14)

            if isExpanded {
                Rectangle()
                    .fill(FlomoPalette.border(scheme))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 14) {
                    // Label + Quick Presets
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("提醒名称")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                            Spacer()
                            HStack(spacing: 5) {
                                ForEach(labelPresets, id: \.self) { preset in
                                    presetChip(preset, active: draftLabel == preset) {
                                        draftLabel = preset
                                        commitDraft()
                                    }
                                }
                            }
                        }

                        TextField("例如：晚间总结 / 晨间复盘", text: $draftLabel)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(FlomoPalette.canvas(scheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(FlomoPalette.border(scheme), lineWidth: 1)
                            )
                            .onChange(of: draftLabel) { _, _ in commitDraft() }
                    }

                    // Time Picker Row
                    HStack {
                        Text("提醒时间")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                        Spacer()
                        Picker("时", selection: $draftHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d 时", h)).tag(h)
                            }
                        }
                        .frame(width: 88)
                        .onChange(of: draftHour) { _, _ in commitDraft() }

                        Picker("分", selection: $draftMinute) {
                            ForEach(0..<60, id: \.self) { m in
                                Text(String(format: "%02d 分", m)).tag(m)
                            }
                        }
                        .frame(width: 88)
                        .onChange(of: draftMinute) { _, _ in commitDraft() }
                    }

                    // Repeat Weekdays
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("重复周期")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                            Spacer()
                            HStack(spacing: 5) {
                                presetChip("每天", active: draftWeekdays == ReviewReminder.allWeekdays) {
                                    draftWeekdays = ReviewReminder.allWeekdays
                                    commitDraft()
                                }
                                presetChip("工作日", active: draftWeekdays == ReviewReminder.workdays) {
                                    draftWeekdays = ReviewReminder.workdays
                                    commitDraft()
                                }
                                presetChip("周末", active: draftWeekdays == ReviewReminder.weekends) {
                                    draftWeekdays = ReviewReminder.weekends
                                    commitDraft()
                                }
                            }
                        }

                        HStack(spacing: 6) {
                            ForEach(weekdayItems, id: \.0) { wd, label in
                                let selected = draftWeekdays.contains(wd)
                                Button {
                                    if selected {
                                        if draftWeekdays.count > 1 { draftWeekdays.remove(wd) }
                                    } else {
                                        draftWeekdays.insert(wd)
                                    }
                                    commitDraft()
                                } label: {
                                    Text("周\(label)")
                                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                        .foregroundColor(selected ? .white : FlomoPalette.textSecondary(scheme))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(selected ? FlomoPalette.accent(scheme) : FlomoPalette.canvas(scheme))
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
                                .whimClickable(cornerRadius: 7, hoverFill: false)
                            }
                        }
                    }

                    // Footer Actions
                    HStack {
                        WhimSecondaryButton(title: "删除提醒", icon: "trash", destructive: true, compact: true) {
                            onDelete()
                        }
                        Spacer()
                        WhimPrimaryButton(title: "完成", compact: true) {
                            commitDraft()
                            onToggleExpand()
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(14)
                .background(FlomoPalette.cardElevated(scheme).opacity(0.45))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FlomoPalette.card(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isExpanded ? FlomoPalette.accent(scheme).opacity(0.65) : FlomoPalette.border(scheme), lineWidth: isExpanded ? 1.2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { syncDraftFromReminder() }
        .onChange(of: reminder) { _, _ in syncDraftFromReminder() }
    }

    private func syncDraftFromReminder() {
        draftLabel = reminder.label
        draftHour = reminder.hour
        draftMinute = reminder.minute
        draftWeekdays = reminder.weekdays
    }

    private func commitDraft() {
        var updated = reminder
        updated.label = draftLabel
        updated.hour = draftHour
        updated.minute = draftMinute
        updated.weekdays = draftWeekdays.isEmpty ? ReviewReminder.allWeekdays : draftWeekdays
        if updated != reminder {
            onUpdate(updated)
        }
    }

    private func presetChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : FlomoPalette.textSecondary(scheme))
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? FlomoPalette.accent(scheme) : FlomoPalette.canvas(scheme))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
        .whimClickable(cornerRadius: 6, hoverFill: false)
    }
}
