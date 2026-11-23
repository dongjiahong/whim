import AppKit
import SwiftUI
@preconcurrency import UserNotifications

enum SidebarTab: Equatable {
    case all
    case review
    case random
    case archived
    case day(String) // YYYY-MM-DD from heatmap click
    case tag(String)
}

@MainActor
final class WhimStoreVM: ObservableObject {
    @Published var displayedNotes: [WhimNote] = []
    @Published var hasMore: Bool = false
    @Published var isLoadingMore: Bool = false
    @Published var tagTree: [WhimTagNode] = []
    @Published var searchQuery: String = ""
    @Published var activeTab: SidebarTab = .all
    @Published var reviewDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var pairCode: String = ""
    @Published var syncMessage: String = ""
    @Published var isSyncing: Bool = false
    @Published var peerStatuses: [WhimPeerSyncStatus] = []
    @Published var dailyReviewEnabled: Bool = UserDefaults.standard.object(forKey: "whim.review.enabled") as? Bool ?? true
    @Published var reviewHour: Int = UserDefaults.standard.object(forKey: "whim.review.hour") as? Int ?? 21
    @Published var reviewMinute: Int = UserDefaults.standard.object(forKey: "whim.review.minute") as? Int ?? 30

    // Undo delete toast
    @Published var lastDeletedNoteId: String? = nil
    private var undoDismissTask: DispatchWorkItem?
    private var searchDebounceTask: DispatchWorkItem?
    private var nextCursor: WhimNoteCursor? = nil
    private var filterRequestGen: Int = 0
    private let pageSize: Int = 50
    private let ioQueue = DispatchQueue(label: "whim.store.io", qos: .userInitiated)

    // Stats for sidebar (computed in SQLite)
    @Published var totalNoteCount: Int = 0
    @Published var totalTagCount: Int = 0
    @Published var activeDayCount: Int = 1
    @Published var dailyCounts: [String: Int] = [:]

    let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func boot() {
        do {
            try CoreBridge.shared.initialize()
            let port = try CoreBridge.shared.startPeerServer(port: 8788)
            pairCode = (try? CoreBridge.shared.getPairCode()) ?? ""
            syncMessage = "局域网监听 :\(port)"
            seedSampleNotesIfEmpty()
            reload()
            scheduleDailyReviewNotification()
            startAutoSyncTimer()
            syncNow()
        } catch {
            syncMessage = "初始化失败: \(error.localizedDescription)"
        }
    }

    func reload() {
        refreshMetadata()
        applyFilter()
    }

    func refreshMetadata() {
        ioQueue.async { [weak self] in
            let stats = try? CoreBridge.shared.getStats(days: 90)
            let tree = try? CoreBridge.shared.listTagTree()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let stats {
                    self.totalNoteCount = stats.totalNotes
                    self.totalTagCount = stats.totalTags
                    self.activeDayCount = stats.activeDays
                    self.dailyCounts = stats.dailyCounts
                }
                if let tree {
                    self.tagTree = tree
                }
            }
        }
    }

    func scheduleSearchFilter() {
        searchDebounceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.applyFilter()
        }
        searchDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    func applyFilter() {
        filterRequestGen += 1
        let gen = filterRequestGen
        let tab = activeTab
        let query = searchQuery
        let revDate = reviewDate
        let limit = pageSize
        nextCursor = nil
        hasMore = false
        isLoadingMore = false

        if tab == .random {
            reshuffleRandom()
            return
        }

        let dayRange: (Int64, Int64)? = { () -> (Int64, Int64)? in
            switch tab {
            case .review:
                let start = Calendar.current.startOfDay(for: revDate)
                let end = start.addingTimeInterval(86400 - 0.001)
                return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
            case .day(let dayStr):
                guard let d = dayFmt.date(from: dayStr) else { return nil }
                let start = Calendar.current.startOfDay(for: d)
                let end = start.addingTimeInterval(86400 - 0.001)
                return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
            default:
                return nil
            }
        }()

        ioQueue.async { [weak self] in
            do {
                let page: WhimNotePage
                switch tab {
                case .all:
                    page = try CoreBridge.shared.listNotesPage(query: query, limit: limit)
                case .review, .day:
                    if let (fromMs, toMs) = dayRange {
                        page = try CoreBridge.shared.listNotesPage(
                            query: query,
                            dateFromMs: fromMs,
                            dateToMs: toMs,
                            includeArchived: true,
                            limit: limit
                        )
                    } else {
                        page = WhimNotePage(notes: [], hasMore: false, nextCursor: nil)
                    }
                case .archived:
                    page = try CoreBridge.shared.listNotesPage(query: query, onlyArchived: true, limit: limit)
                case .tag(let path):
                    page = try CoreBridge.shared.listNotesPage(query: query, tagPrefix: path, limit: limit)
                case .random:
                    page = WhimNotePage(notes: [], hasMore: false, nextCursor: nil)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.filterRequestGen == gen else { return }
                    self.displayedNotes = page.notes
                    self.hasMore = page.hasMore
                    self.nextCursor = page.nextCursor
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.syncMessage = error.localizedDescription
                }
            }
        }
    }

    func loadMore() {
        guard hasMore, !isLoadingMore, let cursor = nextCursor, activeTab != .random else { return }
        isLoadingMore = true
        let gen = filterRequestGen
        let tab = activeTab
        let query = searchQuery
        let revDate = reviewDate
        let limit = pageSize

        let dayRange: (Int64, Int64)? = { () -> (Int64, Int64)? in
            switch tab {
            case .review:
                let start = Calendar.current.startOfDay(for: revDate)
                let end = start.addingTimeInterval(86400 - 0.001)
                return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
            case .day(let dayStr):
                guard let d = dayFmt.date(from: dayStr) else { return nil }
                let start = Calendar.current.startOfDay(for: d)
                let end = start.addingTimeInterval(86400 - 0.001)
                return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
            default:
                return nil
            }
        }()

        ioQueue.async { [weak self] in
            do {
                let page: WhimNotePage
                switch tab {
                case .all:
                    page = try CoreBridge.shared.listNotesPage(query: query, limit: limit, cursor: cursor)
                case .review, .day:
                    if let (fromMs, toMs) = dayRange {
                        page = try CoreBridge.shared.listNotesPage(
                            query: query,
                            dateFromMs: fromMs,
                            dateToMs: toMs,
                            includeArchived: true,
                            limit: limit,
                            cursor: cursor
                        )
                    } else {
                        page = WhimNotePage(notes: [], hasMore: false, nextCursor: nil)
                    }
                case .archived:
                    page = try CoreBridge.shared.listNotesPage(query: query, onlyArchived: true, limit: limit, cursor: cursor)
                case .tag(let path):
                    page = try CoreBridge.shared.listNotesPage(query: query, tagPrefix: path, limit: limit, cursor: cursor)
                case .random:
                    page = WhimNotePage(notes: [], hasMore: false, nextCursor: nil)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.filterRequestGen == gen else { return }
                    self.isLoadingMore = false
                    let existing = Set(self.displayedNotes.map(\.id))
                    let fresh = page.notes.filter { !existing.contains($0.id) }
                    self.displayedNotes.append(contentsOf: fresh)
                    self.hasMore = page.hasMore && !fresh.isEmpty
                    self.nextCursor = page.nextCursor
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.filterRequestGen == gen else { return }
                    self.isLoadingMore = false
                    self.syncMessage = error.localizedDescription
                }
            }
        }
    }

    func reshuffleRandom() {
        filterRequestGen += 1
        let gen = filterRequestGen
        let query = searchQuery
        hasMore = false
        nextCursor = nil
        ioQueue.async { [weak self] in
            let items = (try? CoreBridge.shared.listRandomNotes(query: query, limit: 10)) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.filterRequestGen == gen else { return }
                self.displayedNotes = items
            }
        }
    }

    func shiftReviewDay(by days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: reviewDate) {
            let today = Calendar.current.startOfDay(for: Date())
            reviewDate = min(next, today)
            applyFilter()
        }
    }

    func jumpReviewToday() {
        reviewDate = Calendar.current.startOfDay(for: Date())
        applyFilter()
    }

    func createNote(content: String, attachments: [WhimAttachment]) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        do {
            _ = try CoreBridge.shared.createNote(content: trimmed, attachments: attachments)
            reload()
            syncNow()
        } catch {
            syncMessage = "保存失败: \(error.localizedDescription)"
        }
    }

    func editNote(id: String, content: String, attachments: [WhimAttachment]) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        do {
            _ = try CoreBridge.shared.updateNote(id: id, content: trimmed, attachments: attachments)
            reload()
            syncNow()
        } catch {
            syncMessage = "更新失败: \(error.localizedDescription)"
        }
    }

    func togglePin(_ note: WhimNote) {
        _ = try? CoreBridge.shared.updateNote(id: note.id, pinned: !note.pinned)
        reload()
        syncNow()
    }

    func toggleArchive(_ note: WhimNote) {
        _ = try? CoreBridge.shared.updateNote(id: note.id, archived: !note.archived)
        reload()
        syncNow()
    }

    func deleteNote(_ note: WhimNote) {
        _ = try? CoreBridge.shared.updateNote(id: note.id, deleted: true)
        reload()
        syncNow()
        lastDeletedNoteId = note.id
        undoDismissTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.lastDeletedNoteId = nil
        }
        undoDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: task)
    }

    func undoLastDelete() {
        guard let id = lastDeletedNoteId else { return }
        undoDismissTask?.cancel()
        lastDeletedNoteId = nil
        _ = try? CoreBridge.shared.updateNote(id: id, deleted: false)
        reload()
        syncNow()
    }

    private func startAutoSyncTimer() {
        // Real-time event loop: wakes up in < 50ms when a phone pushes a change or another Mac sends an SSE event
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while self != nil {
                let changed = CoreBridge.shared.waitForChange(timeoutSec: 25)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if changed {
                        self.reload()
                        self.syncNow()
                    }
                }
            }
        }
    }

    func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        syncMessage = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let res = try? CoreBridge.shared.syncOnce(timeoutSec: 6)
            DispatchQueue.main.async {
                self.isSyncing = false
                var hasRemoteUpdates = false
                if let res {
                    self.peerStatuses = res.peers ?? []
                    hasRemoteUpdates = res.notesMerged > 0 || res.blobsDownloaded > 0
                    if res.peersSynced > 0 {
                        self.syncMessage = "已同步 \(res.peersSynced) 台设备" + (res.notesMerged > 0 ? " · 合并 \(res.notesMerged) 条" : "")
                    } else if let firstErr = self.peerStatuses.first(where: { $0.status != "synced" }) {
                        self.syncMessage = firstErr.message
                    } else {
                        self.syncMessage = ""
                    }
                }
                self.refreshSyncState()
                if hasRemoteUpdates {
                    self.reload()
                }
            }
        }
    }

    func refreshSyncState() {
        pairCode = (try? CoreBridge.shared.getPairCode()) ?? pairCode
    }

    func useOtherDeviceCode(_ code: String) {
        do {
            let updated = try CoreBridge.shared.setPairCode(code)
            pairCode = updated
            syncMessage = "已切换到新配对码，正在自动发现并同步..."
            syncNow()
        } catch {
            syncMessage = error.localizedDescription
        }
    }

    func saveManualFallbackAddr(_ addr: String) {
        let trimmed = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? CoreBridge.shared.setManualPeers([trimmed])
        syncNow()
    }

    func regeneratePairCode() {
        if let updated = try? CoreBridge.shared.regeneratePairCode() {
            pairCode = updated
            syncMessage = "已重新生成配对码"
            syncNow()
        }
    }

    func exportMarkdown() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmm"
        let outDir = downloads.appendingPathComponent("Whim-Export-\(fmt.string(from: Date()))")
        if let res = try? CoreBridge.shared.exportMarkdown(outDir: outDir.path) {
            syncMessage = "已导出 \(res.notesExported) 条到 \(outDir.lastPathComponent)"
            NSWorkspace.shared.open(outDir)
        }
    }

    // MARK: - Dev Sample Data Seeding

    func seedSampleNotesIfEmpty() {
        let existing = (try? CoreBridge.shared.listNotes(includeArchived: true, limit: 5)) ?? []
        guard existing.isEmpty else { return }
        seedSampleNotes()
    }

    func seedSampleNotes() {
        // Generate two clean inline PNG sample cards to demonstrate multi-image interleaved positioning
        let img1Data = makeSamplePNG(title: "1. 局域网 P2P 发现", subtitle: "UDP 广播 8789 → 源地址回读 IP", bgHex: 0x223029)
        let img2Data = makeSamplePNG(title: "2. 图文内联 Blob 同步", subtitle: "![image](whim://blob/<sha256>)", bgHex: 0x1E2A3A)

        var att1: WhimAttachment?
        var att2: WhimAttachment?
        if let d1 = img1Data, let s1 = try? CoreBridge.shared.saveBlob(data: d1, mime: "image/png") {
            att1 = WhimAttachment(sha256: s1.sha256, mime: s1.mime, sizeBytes: s1.sizeBytes, localPath: s1.localPath)
        }
        if let d2 = img2Data, let s2 = try? CoreBridge.shared.saveBlob(data: d2, mime: "image/png") {
            att2 = WhimAttachment(sha256: s2.sha256, mime: s2.mime, sizeBytes: s2.sizeBytes, localPath: s2.localPath)
        }

        let samples: [(String, [WhimAttachment], Bool)] = [
            (
                """
                #PA/感悟 #示例
                1. 一定不要在区间的上下沿压注突破，即便是短期突破了上下沿，想做区间的 MM 也要等回调确认支撑后再入场，虽然机会少一点，但不至于亏钱。
                2. 如果入场逻辑正确，大概率先浮盈；如果一进场就立刻浮亏，说明逻辑错了，不要扛单。
                3. 所有的突破都要等确认后再下单，不要在区间中段追单。
                """,
                [],
                true
            ),
            (
                {
                    let line1 = "#项目/whim/架构 #示例\n测试多图内联混排：第一张图紧跟在这段架构说明下面："
                    let mid1 = att1.map { "\n![image](whim://blob/\($0.sha256))\n" } ?? "\n"
                    let line2 = "接着写第二段想法——在编辑器里直接按 ⌘V 粘贴图片，图片会精准留在光标位置，而不是堆到底部："
                    let mid2 = att2.map { "\n![image](whim://blob/\($0.sha256))\n" } ?? "\n"
                    let line3 = "最后补充一句：导出 Markdown 时也会原样保留图文顺序。"
                    return line1 + mid1 + line2 + mid2 + line3
                }(),
                [att1, att2].compactMap { $0 },
                false
            ),
            (
                "#读书/方法论 #示例\n记笔记最难的不是写，而是打开笔记。把输入阻力降到一次快捷键（⌘⇧J）和一个下拉快捷开关，持续记录的意义才会自然浮现。",
                [],
                false
            ),
            (
                "#工作/MCP #示例\n每周五晚上用 Claude / Cursor 连上本地 whim-mcp，把本周零散的想法按主题聚类、补充多级标签并提炼成周复盘。",
                [],
                false
            ),
            (
                "#灵感/产品 #示例\n悬浮新建窗加上 Pin 固定按钮后，看盘或读论文时可以常驻屏幕一角，写完一条 ⌘↩ 直接继续记下一条，不会打断上下文。",
                [],
                false
            )
        ]

        for (body, atts, pinned) in samples {
            if let created = try? CoreBridge.shared.createNote(content: body, attachments: atts), pinned {
                _ = try? CoreBridge.shared.updateNote(id: created.id, pinned: true)
            }
        }
        reload()
    }

    func clearSampleNotes() {
        var cursor: WhimNoteCursor? = nil
        while let page = try? CoreBridge.shared.listNotesPage(tagPrefix: "示例", includeArchived: true, limit: 200, cursor: cursor) {
            for n in page.notes {
                _ = try? CoreBridge.shared.updateNote(id: n.id, deleted: true)
            }
            if !page.hasMore || page.nextCursor == nil { break }
            cursor = page.nextCursor
        }
        reload()
    }

    private func makeSamplePNG(title: String, subtitle: String, bgHex: UInt32) -> Data? {
        let size = NSSize(width: 440, height: 150)
        let img = NSImage(size: size)
        img.lockFocus()
        let bg = NSColor(
            red: CGFloat((bgHex >> 16) & 0xFF) / 255.0,
            green: CGFloat((bgHex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(bgHex & 0xFF) / 255.0,
            alpha: 1.0
        )
        bg.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 12, yRadius: 12).fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor(white: 0.94, alpha: 1.0)
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.72, alpha: 1.0)
        ]
        (title as NSString).draw(at: NSPoint(x: 24, y: 86), withAttributes: titleAttrs)
        (subtitle as NSString).draw(at: NSPoint(x: 24, y: 52), withAttributes: subAttrs)
        img.unlockFocus()

        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    var allFlatTags: [String] {
        var out: [String] = []
        func walk(_ nodes: [WhimTagNode]) {
            for n in nodes {
                out.append(n.fullPath)
                if let c = n.children { walk(c) }
            }
        }
        walk(tagTree)
        return out
    }

    func saveReviewSchedule() {
        UserDefaults.standard.set(dailyReviewEnabled, forKey: "whim.review.enabled")
        UserDefaults.standard.set(reviewHour, forKey: "whim.review.hour")
        UserDefaults.standard.set(reviewMinute, forKey: "whim.review.minute")
        scheduleDailyReviewNotification()
    }

    private func scheduleDailyReviewNotification() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["whim.daily.review"])
        guard dailyReviewEnabled else { return }
        let hour = reviewHour
        let minute = reviewMinute
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "晚间复盘 · Whim"
            content.body = "花 2 分钟回顾今天记录的闪念，整理关键想法。"
            content.sound = .default
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            let req = UNNotificationRequest(identifier: "whim.daily.review", content: content, trigger: trigger)
            center.add(req)
        }
    }
}

// MARK: - Activity Heatmap (12 weeks x 7 days, clickable to filter by day)

private enum HeatmapCalendarCache {
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MMM"
        return f
    }()

    private static var cachedTodayKey: String = ""
    private static var cachedGridKeys: [[String]] = []
    private static var cachedMonths: [String] = []

    static func snapshot() -> (todayKey: String, gridKeys: [[String]], monthLabels: [String]) {
        let now = Date()
        let todayKey = dayFmt.string(from: now)
        if todayKey == cachedTodayKey, !cachedGridKeys.isEmpty {
            return (todayKey, cachedGridKeys, cachedMonths)
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let columns = 12
        let rows = 7
        let totalDays = columns * rows
        var cols: [[String]] = []
        if let start = cal.date(byAdding: .day, value: -(totalDays - 1), to: today) {
            cols.reserveCapacity(columns)
            for c in 0..<columns {
                var col: [String] = []
                col.reserveCapacity(rows)
                for r in 0..<rows {
                    if let d = cal.date(byAdding: .day, value: c * rows + r, to: start) {
                        col.append(dayFmt.string(from: d))
                    }
                }
                cols.append(col)
            }
        }
        let months = [-2, -1, 0].compactMap { offset in
            cal.date(byAdding: .month, value: offset, to: now).map { monthFmt.string(from: $0) }
        }
        cachedTodayKey = todayKey
        cachedGridKeys = cols
        cachedMonths = months
        return (todayKey, cols, months)
    }
}

struct ActivityHeatmapView: View {
    @Environment(\.colorScheme) private var scheme
    let dailyCounts: [String: Int]
    let selectedDay: String?
    let onSelectDay: (String) -> Void

    var body: some View {
        let snap = HeatmapCalendarCache.snapshot()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<snap.gridKeys.count, id: \.self) { colIdx in
                    VStack(spacing: 4) {
                        ForEach(0..<snap.gridKeys[colIdx].count, id: \.self) { rowIdx in
                            let key = snap.gridKeys[colIdx][rowIdx]
                            let cnt = dailyCounts[key] ?? 0
                            let isToday = key == snap.todayKey
                            let isSelected = key == selectedDay
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(FlomoPalette.heatmapCell(cnt, scheme: scheme))
                                .frame(width: 13, height: 13)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .stroke(
                                            isSelected ? FlomoPalette.tagText(scheme) : (isToday ? FlomoPalette.textSecondary(scheme) : .clear),
                                            lineWidth: isSelected ? 1.5 : 1
                                        )
                                )
                                .onTapGesture { onSelectDay(key) }
                                .help("\(key)：\(cnt) 条笔记（点击查看当日）")
                        }
                    }
                }
            }
            HStack {
                ForEach(snap.monthLabels, id: \.self) { m in
                    Text(m)
                        .font(.system(size: 10.5))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                    if m != snap.monthLabels.last { Spacer() }
                }
            }
            .padding(.trailing, 18)
        }
    }
}

// MARK: - Inline Composer (True NSTextView with inline Cmd+V image paste)

struct FlomoComposerView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: WhimStoreVM
    var editingNote: WhimNote? = nil
    var onFinishEdit: (() -> Void)? = nil

    @StateObject private var editor = InlineEditorController()
    @State private var markdown: String = ""
    @State private var attachments: [WhimAttachment] = []
    @State private var isFocused: Bool = false
    @State private var selectedTagIndex: Int = 0

    private var canSubmit: Bool {
        !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var activeTagQuery: String? {
        guard let idx = markdown.lastIndex(of: "#") else { return nil }
        let tail = String(markdown[markdown.index(after: idx)...])
        if tail.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
        return tail
    }

    private var tagSuggestions: [String] {
        guard let q = activeTagQuery else { return [] }
        return vm.allFlatTags.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if markdown.isEmpty {
                    Text("现在的想法是...（直接 ⌘V 可在光标处插入图片）")
                        .font(.system(size: 14))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                        .padding(.top, 5)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
                InlineRichEditor(
                    controller: editor,
                    initialMarkdown: editingNote?.content ?? "",
                    initialAttachments: editingNote?.attachments,
                    autoFocus: editingNote != nil,
                    isDark: scheme == .dark,
                    onTextChange: { md, atts in
                        markdown = md
                        attachments = atts
                        selectedTagIndex = 0
                    },
                    onFocusChange: { focused in isFocused = focused },
                    onSubmit: submit,
                    onEscape: { onFinishEdit?() },
                    onNavigateSuggestion: { delta in
                        let items = tagSuggestions
                        guard !items.isEmpty else { return false }
                        selectedTagIndex = (selectedTagIndex + delta + items.count) % items.count
                        return true
                    },
                    onAcceptSuggestion: {
                        let items = tagSuggestions
                        guard !items.isEmpty else { return false }
                        let safeIdx = min(max(0, selectedTagIndex), items.count - 1)
                        editor.replaceActiveTag(with: items[safeIdx])
                        selectedTagIndex = 0
                        return true
                    }
                )
                .frame(minHeight: editingNote != nil ? 120 : 86, maxHeight: 240)
            }

            if !tagSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(tagSuggestions.enumerated()), id: \.element) { idx, tag in
                            let active = idx == min(selectedTagIndex, tagSuggestions.count - 1)
                            Button {
                                editor.replaceActiveTag(with: tag)
                                selectedTagIndex = 0
                            } label: {
                                Text("#\(tag)")
                                    .font(.system(size: 12, weight: active ? .medium : .regular))
                                    .foregroundColor(active ? .white : FlomoPalette.tagText(scheme))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(active ? FlomoPalette.accent(scheme) : FlomoPalette.tagBg(scheme))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                toolbarIcon("number", help: "插入标签 (#)") {
                    editor.insertSnippet(markdown.isEmpty || markdown.hasSuffix(" ") || markdown.hasSuffix("\n") ? "#" : " #")
                    editor.focus()
                }
                toolbarIcon("photo", help: "从本地选择图片插入光标处（剪贴板图片直接 ⌘V）") {
                    editor.pickImageFromFinder()
                }

                Spacer()

                if let onFinishEdit {
                    Button("取消") { onFinishEdit() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                }

                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(canSubmit ? 1.0 : 0.45))
                        .frame(width: 38, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(FlomoPalette.accent(scheme).opacity(canSubmit ? 1.0 : 0.45))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FlomoPalette.composer(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isFocused || editingNote != nil ? FlomoPalette.accent(scheme) : FlomoPalette.border(scheme),
                    lineWidth: isFocused || editingNote != nil ? 1.2 : 1
                )
        )
        .onAppear {
            if let editingNote {
                markdown = editingNote.content
                attachments = editingNote.attachments ?? []
            }
        }
    }

    private func toolbarIcon(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundColor(FlomoPalette.textSecondary(scheme))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func submit() {
        let (md, atts) = editor.serialize()
        let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !atts.isEmpty else { return }

        if let editingNote {
            vm.editNote(id: editingNote.id, content: trimmed, attachments: atts)
            onFinishEdit?()
        } else {
            vm.createNote(content: trimmed, attachments: atts)
            editor.clear()
            markdown = ""
            attachments = []
        }
    }
}

// MARK: - Main Flomo-Style Two-Column Window

struct MainContentView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: WhimStoreVM
    let onOpenQuickCapture: () -> Void
    let onToggleWindowPin: (Bool) -> Void

    @AppStorage("whim.themeMode") private var themeModeRaw: String = AppThemeMode.system.rawValue
    @State private var showSettingsSheet: Bool = false
    @State private var settingsInitialSection: SettingsSection = .general
    @State private var previewImagePath: String? = nil
    @State private var editingNoteId: String? = nil
    @State private var mainWindowPinned: Bool = false
    @FocusState private var searchFocused: Bool

    private var selectedHeatmapDay: String? {
        if case .day(let d) = vm.activeTab { return d }
        return nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                // Left Sidebar (248pt)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Text("Whim")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                        Text("LOCAL")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(FlomoPalette.border(scheme)))
                        Spacer()
                    }
                    .padding(.top, 30)

                    // 3-Column Stats
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        statBlock(value: "\(vm.totalNoteCount)", label: "笔记")
                        Spacer()
                        statBlock(value: "\(vm.totalTagCount)", label: "标签")
                        Spacer()
                        statBlock(value: "\(vm.activeDayCount)", label: "天")
                        Spacer()
                    }

                    // 12-Week Interactive Heatmap
                    ActivityHeatmapView(
                        dailyCounts: vm.dailyCounts,
                        selectedDay: selectedHeatmapDay,
                        onSelectDay: { dayStr in
                            vm.activeTab = .day(dayStr)
                            vm.applyFilter()
                        }
                    )
                    .padding(.vertical, 2)

                    // Navigation Pills
                    VStack(spacing: 3) {
                        navRow(icon: "square.grid.2x2.fill", title: "全部笔记", active: vm.activeTab == .all) {
                            vm.activeTab = .all
                            vm.applyFilter()
                        }
                        navRow(icon: "sparkles", title: "每日回顾", active: vm.activeTab == .review) {
                            vm.activeTab = .review
                            vm.applyFilter()
                        }
                        navRow(icon: "shuffle", title: "随机漫步", active: vm.activeTab == .random) {
                            vm.activeTab = .random
                            vm.applyFilter()
                        }
                        navRow(icon: "archivebox", title: "已归档", active: vm.activeTab == .archived) {
                            vm.activeTab = .archived
                            vm.applyFilter()
                        }
                    }

                    Text("全部标签")
                        .font(.system(size: 11.5))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                        .padding(.top, 6)
                        .padding(.leading, 4)

                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.tagTree) { node in
                                FlomoTagRow(node: node, depth: 0, activeTab: vm.activeTab) { path in
                                    vm.activeTab = .tag(path)
                                    vm.applyFilter()
                                }
                            }
                        }
                    }

                    Divider().opacity(0.25)
                    Button { showSettingsSheet = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 12))
                            Text("设置 · v\(GitHubUpdater.currentVersion)")
                                .font(.system(size: 12))
                            Spacer()
                        }
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .frame(width: 248)
                .background(FlomoPalette.sidebar(scheme))

                // Right Main Column
                VStack(alignment: .leading, spacing: 14) {
                    // Top Bar: Title + Search (⌘K) + Pin + Utility Menu
                    HStack(spacing: 12) {
                        Text(currentTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))

                        if case .day = vm.activeTab {
                            Button("清除日期") {
                                vm.activeTab = .all
                                vm.applyFilter()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundColor(FlomoPalette.tagText(scheme))
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12))
                                .foregroundColor(FlomoPalette.textMuted(scheme))
                            TextField("⌘+K 搜索...", text: $vm.searchQuery)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundColor(FlomoPalette.textPrimary(scheme))
                                .focused($searchFocused)
                                .onChange(of: vm.searchQuery) { _, _ in vm.scheduleSearchFilter() }
                            if !vm.searchQuery.isEmpty {
                                Button {
                                    vm.searchQuery = ""
                                    vm.applyFilter()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(FlomoPalette.textMuted(scheme))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(width: 215)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(FlomoPalette.searchBg(scheme))
                        )

                        Button {
                            mainWindowPinned.toggle()
                            onToggleWindowPin(mainWindowPinned)
                        } label: {
                            Image(systemName: mainWindowPinned ? "pin.fill" : "pin")
                                .font(.system(size: 12.5))
                                .foregroundColor(mainWindowPinned ? FlomoPalette.accent(scheme) : FlomoPalette.textSecondary(scheme))
                        }
                        .buttonStyle(.plain)
                        .help(mainWindowPinned ? "取消主窗口置顶" : "主窗口置顶")

                        Menu {
                            Button("新建浮窗 (⌘⇧J)", action: onOpenQuickCapture)
                            Button("立即局域网同步") { vm.syncNow() }
                            Button("导出 Markdown") { vm.exportMarkdown() }
                            Divider()
                            Button("注入示例数据") { vm.seedSampleNotes() }
                            Button("清除示例数据") { vm.clearSampleNotes() }
                            Divider()
                            Button("偏好设置与更新... (⌘,)") { showSettingsSheet = true }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 22)
                    }
                    .padding(.top, 14)

                    // Contextual Sub-headers for Daily Review & Random Walk
                    if vm.activeTab == .review {
                        dailyReviewBar
                    } else if vm.activeTab == .random {
                        randomWalkBar
                    } else if vm.activeTab != .archived {
                        // Inline Flomo Composer right at top of feed
                        FlomoComposerView(vm: vm)
                    }

                    // Note Card Feed (NSTableView-backed List for true cell recycling & 120Hz scrolling)
                    ScrollViewReader { scrollProxy in
                        List {
                            Color.clear
                                .frame(height: 0)
                                .id("__feed_top__")
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())

                            if vm.displayedNotes.isEmpty {
                                VStack(spacing: 8) {
                                    Text(vm.searchQuery.isEmpty ? "暂无记录" : "未找到匹配“\(vm.searchQuery)”的笔记")
                                        .font(.system(size: 14))
                                        .foregroundColor(FlomoPalette.textMuted(scheme))
                                    if vm.searchQuery.isEmpty {
                                        Text("在上方输入框记下想法（支持 ⌘V 光标处贴图），或随时按 ⌘⇧J 呼出悬浮速记")
                                            .font(.system(size: 12))
                                            .foregroundColor(FlomoPalette.textMuted(scheme))
                                    } else {
                                        Button("清除搜索") {
                                            vm.searchQuery = ""
                                            vm.applyFilter()
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12.5))
                                        .foregroundColor(FlomoPalette.tagText(scheme))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 56)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                            } else {
                                let notes = vm.displayedNotes
                                let prefetchIdx = max(0, notes.count - 5)
                                let prefetchId = notes.indices.contains(prefetchIdx) ? notes[prefetchIdx].id : nil

                                ForEach(notes) { note in
                                    Group {
                                        if editingNoteId == note.id {
                                            FlomoComposerView(vm: vm, editingNote: note) {
                                                editingNoteId = nil
                                            }
                                        } else {
                                            FlomoNoteCard(
                                                note: note,
                                                onTapTag: { path in
                                                    vm.activeTab = .tag(path)
                                                    vm.applyFilter()
                                                },
                                                onTapImage: { path in previewImagePath = path },
                                                onEdit: { editingNoteId = note.id },
                                                onPin: { vm.togglePin(note) },
                                                onArchive: { vm.toggleArchive(note) },
                                                onDelete: { vm.deleteNote(note) }
                                            )
                                        }
                                    }
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 4))
                                    .onAppear {
                                        if vm.hasMore && note.id == prefetchId {
                                            vm.loadMore()
                                        }
                                    }
                                }

                                Group {
                                    if vm.isLoadingMore {
                                        HStack(spacing: 8) {
                                            ProgressView().controlSize(.small)
                                            Text("正在加载更多...")
                                                .font(.system(size: 12))
                                                .foregroundColor(FlomoPalette.textMuted(scheme))
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                    } else if vm.hasMore {
                                        Button("加载更多") { vm.loadMore() }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 12.5))
                                            .foregroundColor(FlomoPalette.tagText(scheme))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                    } else if notes.count >= 20 {
                                        Text("已加载全部 \(notes.count) 条")
                                            .font(.system(size: 11.5))
                                            .foregroundColor(FlomoPalette.textMuted(scheme))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                    }
                                }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 32, trailing: 0))
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onChange(of: vm.activeTab) { _, _ in
                            scrollProxy.scrollTo("__feed_top__", anchor: .top)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FlomoPalette.canvas(scheme))
            }

            // Undo Delete Toast
            if vm.lastDeletedNoteId != nil {
                HStack(spacing: 12) {
                    Text("已删除一条笔记")
                        .font(.system(size: 13))
                        .foregroundColor(FlomoPalette.textPrimary(scheme))
                    Button("撤销") { vm.undoLastDelete() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FlomoPalette.accent(scheme))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(FlomoPalette.card(scheme))
                        .shadow(color: Color.black.opacity(0.45), radius: 14, y: 6)
                )
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(FlomoPalette.border(scheme), lineWidth: 1))
                .padding(.bottom, 18)
            }

            // Hidden ⌘K Search & ⌘, Settings shortcuts
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            Button("") { showSettingsSheet = true }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .frame(minWidth: 880, minHeight: 620)
        .background(FlomoPalette.canvas(scheme))
        .preferredColorScheme((AppThemeMode(rawValue: themeModeRaw) ?? .system).colorScheme)
        .sheet(isPresented: Binding(get: { previewImagePath != nil }, set: { if !$0 { previewImagePath = nil } })) {
            if let path = previewImagePath, let img = NSImage(contentsOfFile: path) {
                VStack(spacing: 12) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(minWidth: 420, maxWidth: 960, minHeight: 280, maxHeight: 720)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    HStack(spacing: 14) {
                        Button("复制图片") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.writeObjects([img])
                        }
                        Button("关闭") { previewImagePath = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.bottom, 14)
                }
                .background(FlomoPalette.canvas(scheme))
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsModalView(
                vm: vm,
                themeModeRaw: $themeModeRaw,
                initialSection: settingsInitialSection,
                onApplyTheme: { mode in
                    NSApp.appearance = mode.nsAppearance
                },
                onClose: { showSettingsSheet = false }
            )
        }
    }

    private var dailyReviewBar: some View {
        let isToday = Calendar.current.isDateInToday(vm.reviewDate)
        let dateText = vm.dayFmt.string(from: vm.reviewDate)
        return HStack(spacing: 12) {
            Button { vm.shiftReviewDay(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FlomoPalette.textPrimary(scheme))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(FlomoPalette.card(scheme)))
            }
            .buttonStyle(.plain)

            Text(isToday ? "\(dateText) · 今天" : dateText)
                .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                .foregroundColor(FlomoPalette.textPrimary(scheme))

            Button { vm.shiftReviewDay(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isToday ? FlomoPalette.textMuted(scheme) : FlomoPalette.textPrimary(scheme))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(FlomoPalette.card(scheme)))
            }
            .buttonStyle(.plain)
            .disabled(isToday)

            if !isToday {
                Button("回到今天") { vm.jumpReviewToday() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(FlomoPalette.tagText(scheme))
            }

            Spacer()

            Text("当日共 \(vm.displayedNotes.count) 条记录")
                .font(.system(size: 12))
                .foregroundColor(FlomoPalette.textSecondary(scheme))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FlomoPalette.card(scheme)))
    }

    private var randomWalkBar: some View {
        HStack {
            Text("从历史记录中随机抽取灵感，与过往想法不期而遇")
                .font(.system(size: 12.5))
                .foregroundColor(FlomoPalette.textSecondary(scheme))
            Spacer()
            Button { vm.reshuffleRandom() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 11.5))
                    Text("换一批")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(FlomoPalette.accent(scheme)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FlomoPalette.card(scheme)))
    }

    private var currentTitle: String {
        switch vm.activeTab {
        case .all: return "全部笔记"
        case .review: return "每日回顾"
        case .random: return "随机漫步"
        case .archived: return "已归档"
        case .day(let d): return "日期 · \(d)"
        case .tag(let path): return "#\(path)"
        }
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 21, weight: .semibold).monospacedDigit())
                .foregroundColor(FlomoPalette.textPrimary(scheme))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(FlomoPalette.textMuted(scheme))
        }
    }

    private func navRow(icon: String, title: String, active: Bool, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(active ? .white : FlomoPalette.textSecondary(scheme))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13.5, weight: active ? .medium : .regular))
                    .foregroundColor(active ? .white : FlomoPalette.textPrimary(scheme))
                Spacer()
                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? FlomoPalette.accent(scheme) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FlomoTagRow: View {
    @Environment(\.colorScheme) private var scheme
    let node: WhimTagNode
    let depth: Int
    let activeTab: SidebarTab
    let onSelect: (String) -> Void

    @State private var expanded: Bool = true

    private var hasChildren: Bool { !(node.children?.isEmpty ?? true) }
    private var isSelected: Bool {
        if case .tag(let p) = activeTab { return p == node.fullPath }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if hasChildren {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(isSelected ? .white.opacity(0.85) : FlomoPalette.textMuted(scheme))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 14)
                }

                Button { onSelect(node.fullPath) } label: {
                    HStack(spacing: 6) {
                        Text("#")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(isSelected ? .white : FlomoPalette.textMuted(scheme))
                        Text(node.name)
                            .font(.system(size: 13.5))
                            .foregroundColor(isSelected ? .white : FlomoPalette.textPrimary(scheme))
                            .lineLimit(1)
                        Spacer()
                        Text("\(node.count)")
                            .font(.system(size: 11))
                            .foregroundColor(isSelected ? .white.opacity(0.8) : FlomoPalette.textMuted(scheme))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth * 12) + 4)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? FlomoPalette.accent(scheme) : .clear)
            )

            if expanded, let children = node.children {
                ForEach(children) { child in
                    FlomoTagRow(node: child, depth: depth + 1, activeTab: activeTab, onSelect: onSelect)
                }
            }
        }
    }
}

private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxWidth, max(x - spacing, 0)), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct AsyncCardImage: View {
    @Environment(\.colorScheme) private var scheme
    let path: String
    let onTap: (String) -> Void

    @State private var image: NSImage?

    init(path: String, onTap: @escaping (String) -> Void) {
        self.path = path
        self.onTap = onTap
        _image = State(initialValue: ThumbnailCache.shared.cachedImage(forPath: path))
    }

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 460, maxHeight: 280, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { onTap(path) }
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FlomoPalette.canvas(scheme))
                    .frame(width: 240, height: 150)
                    .onAppear {
                        ThumbnailCache.shared.loadImage(forPath: path) { loaded in
                            if let loaded {
                                image = loaded
                            }
                        }
                    }
            }
        }
    }
}

private struct CardHeaderActions: View {
    @Environment(\.colorScheme) private var scheme
    let pinned: Bool
    let archived: Bool
    let content: String
    let onEdit: () -> Void
    let onPin: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var editHovered: Bool = false
    @State private var menuHovered: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundColor(editHovered ? FlomoPalette.textPrimary(scheme) : FlomoPalette.textMuted(scheme))
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(editHovered ? FlomoPalette.border(scheme) : .clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { editHovered = $0 }
            .help("编辑笔记")

            Menu {
                Button("编辑", action: onEdit)
                Button(pinned ? "取消置顶" : "置顶笔记", action: onPin)
                Button(archived ? "取消归档" : "归档", action: onArchive)
                Button("复制正文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                }
                Divider()
                Button("删除", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundColor(menuHovered ? FlomoPalette.textPrimary(scheme) : FlomoPalette.textMuted(scheme))
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(menuHovered ? FlomoPalette.border(scheme) : .clear)
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .onHover { menuHovered = $0 }
        }
    }
}

private struct FlomoNoteCardBody: View, Equatable {
    @Environment(\.colorScheme) private var scheme
    let noteId: String
    let updatedAt: Int64
    let content: String
    let tags: [String]
    let attachments: [WhimAttachment]
    let collapsed: Bool
    let onTapTag: (String) -> Void
    let onTapImage: (String) -> Void

    static func == (lhs: FlomoNoteCardBody, rhs: FlomoNoteCardBody) -> Bool {
        lhs.noteId == rhs.noteId &&
        lhs.updatedAt == rhs.updatedAt &&
        lhs.collapsed == rhs.collapsed &&
        lhs.content == rhs.content &&
        lhs.tags == rhs.tags &&
        lhs.attachments == rhs.attachments
    }

    var body: some View {
        let cacheKey = "\(noteId):\(updatedAt):\(tags.count):\(attachments.count)"
        let blocks = NoteContentParser.parseCached(
            cacheKey: cacheKey,
            content: content,
            attachments: attachments,
            stripTags: tags
        )
        VStack(alignment: .leading, spacing: 10) {
            if !tags.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button { onTapTag(tag) } label: {
                            Text("#\(tag)")
                                .font(.system(size: 12))
                                .foregroundColor(FlomoPalette.tagText(scheme))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(FlomoPalette.tagBg(scheme))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    switch block {
                    case .text(_, let val):
                        MarkdownBlockView(text: val, collapsed: collapsed)
                            .equatable()
                    case .image(_, _, let path):
                        AsyncCardImage(path: path, onTap: onTapImage)
                    }
                }
            }
        }
    }
}

private struct FlomoNoteCard: View {
    @Environment(\.colorScheme) private var scheme
    let note: WhimNote
    let onTapTag: (String) -> Void
    let onTapImage: (String) -> Void
    let onEdit: () -> Void
    let onPin: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var expanded: Bool = false

    private static let cardTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var formattedTime: String {
        let d = Date(timeIntervalSince1970: TimeInterval(note.createdAt) / 1000.0)
        return Self.cardTimeFmt.string(from: d)
    }

    private var isLongNote: Bool {
        note.content.count > 280 || note.content.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } > 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Meta header row (fixed positions, zero hover layout jitter)
            HStack(spacing: 6) {
                Text(note.pinned ? "置顶 · \(formattedTime)" : formattedTime)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(FlomoPalette.textSecondary(scheme))
                Spacer()
                CardHeaderActions(
                    pinned: note.pinned,
                    archived: note.archived,
                    content: note.content,
                    onEdit: onEdit,
                    onPin: onPin,
                    onArchive: onArchive,
                    onDelete: onDelete
                )
            }

            FlomoNoteCardBody(
                noteId: note.id,
                updatedAt: note.updatedAt,
                content: note.content,
                tags: note.tags ?? [],
                attachments: note.attachments ?? [],
                collapsed: !expanded && isLongNote,
                onTapTag: onTapTag,
                onTapImage: onTapImage
            )
            .equatable()

            if isLongNote {
                Button(expanded ? "收起" : "展开") {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(FlomoPalette.tagText(scheme))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FlomoPalette.card(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(FlomoPalette.border(scheme), lineWidth: 0.5)
        )
        .contextMenu {
            Button("编辑", action: onEdit)
            Button(note.pinned ? "取消置顶" : "置顶笔记", action: onPin)
            Button(note.archived ? "取消归档" : "归档", action: onArchive)
            Button("复制正文") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.content, forType: .string)
            }
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Floating Global Hotkey Capture Panel (⌘⇧J, matches flomo quick input + Pin + Inline Cmd+V Image)

final class QuickCapturePanel: NSPanel {
    init(vm: WhimStoreVM, onClose: @escaping () -> Void) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 396, height: 470),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        minSize = NSSize(width: 320, height: 300)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        center()

        let savedTheme = AppThemeMode(rawValue: UserDefaults.standard.string(forKey: "whim.themeMode") ?? "system") ?? .system
        contentView = NSHostingView(
            rootView: FloatingQuickCaptureView(
                vm: vm,
                onTogglePin: { [weak self] pinned in
                    self?.setPinned(pinned)
                },
                onClose: onClose
            )
            .preferredColorScheme(savedTheme.colorScheme)
        )
    }

    func setPinned(_ pinned: Bool) {
        level = pinned ? .floating : .normal
        hidesOnDeactivate = !pinned
    }

    override var canBecomeKey: Bool { true }
}

struct FloatingQuickCaptureView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: WhimStoreVM
    let onTogglePin: (Bool) -> Void
    let onClose: () -> Void

    @StateObject private var editor = InlineEditorController()
    @State private var markdown: String = ""
    @State private var attachments: [WhimAttachment] = []
    @State private var isPinned: Bool = false
    @State private var selectedTagIndex: Int = 0

    private var canSubmit: Bool {
        !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var activeTagQuery: String? {
        guard let idx = markdown.lastIndex(of: "#") else { return nil }
        let tail = String(markdown[markdown.index(after: idx)...])
        if tail.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
        return tail
    }

    private var tagSuggestions: [String] {
        guard let q = activeTagQuery else { return [] }
        return vm.allFlatTags.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("新建")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(FlomoPalette.textPrimary(scheme))
                Spacer()
                Button {
                    isPinned.toggle()
                    onTogglePin(isPinned)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 13))
                        .foregroundColor(isPinned ? FlomoPalette.accent(scheme) : FlomoPalette.textSecondary(scheme))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "已固定在屏幕最前（发送后不关闭）" : "固定在屏幕最前")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("关闭 (Esc)")
            }

            ZStack(alignment: .topLeading) {
                if markdown.isEmpty {
                    Text("现在的想法是...（⌘V 可在光标处插图）")
                        .font(.system(size: 14.5))
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
                        markdown = md
                        attachments = atts
                        selectedTagIndex = 0
                    },
                    onFocusChange: { _ in },
                    onSubmit: submit,
                    onEscape: { if !isPinned { onClose() } },
                    onNavigateSuggestion: { delta in
                        let items = tagSuggestions
                        guard !items.isEmpty else { return false }
                        selectedTagIndex = (selectedTagIndex + delta + items.count) % items.count
                        return true
                    },
                    onAcceptSuggestion: {
                        let items = tagSuggestions
                        guard !items.isEmpty else { return false }
                        let safeIdx = min(max(0, selectedTagIndex), items.count - 1)
                        editor.replaceActiveTag(with: items[safeIdx])
                        selectedTagIndex = 0
                        return true
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !tagSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(tagSuggestions.enumerated()), id: \.element) { idx, tag in
                            let active = idx == min(selectedTagIndex, tagSuggestions.count - 1)
                            Button {
                                editor.replaceActiveTag(with: tag)
                                selectedTagIndex = 0
                            } label: {
                                Text("#\(tag)")
                                    .font(.system(size: 12, weight: active ? .medium : .regular))
                                    .foregroundColor(active ? .white : FlomoPalette.tagText(scheme))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(active ? FlomoPalette.accent(scheme) : FlomoPalette.tagBg(scheme))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                iconBtn("number", help: "插入标签") {
                    editor.insertSnippet(markdown.isEmpty || markdown.hasSuffix(" ") || markdown.hasSuffix("\n") ? "#" : " #")
                    editor.focus()
                }
                iconBtn("photo", help: "从本地选择图片插入光标处（剪贴板图片直接 ⌘V）") {
                    editor.pickImageFromFinder()
                }

                Spacer()

                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(canSubmit ? 1.0 : 0.45))
                        .frame(width: 44, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(FlomoPalette.accent(scheme).opacity(canSubmit ? 1.0 : 0.45))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FlomoPalette.card(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FlomoPalette.border(scheme), lineWidth: 1)
        )
    }

    private func iconBtn(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14))
                .foregroundColor(FlomoPalette.textSecondary(scheme))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func submit() {
        let (md, atts) = editor.serialize()
        let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !atts.isEmpty else { return }
        vm.createNote(content: trimmed, attachments: atts)
        editor.clear()
        markdown = ""
        attachments = []
        if !isPinned {
            onClose()
        } else {
            editor.focus()
        }
    }
}

// MARK: - AppDelegate & Entry

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let vm = WhimStoreVM()
    var statusItem: NSStatusItem?
    var quickPanel: QuickCapturePanel?
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        vm.boot()
        setupMenuBar()
        setupMainWindow()
        GlobalHotKeyManager.shared.registerCmdShiftJ { [weak self] in
            self?.toggleQuickCapture()
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Whim")
        appMenu.addItem(withTitle: "退出 Whim", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Edit menu (required by AppKit for Cmd+C/V/X/A/Z in all windows & text fields)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Window menu
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        mainMenu.addItem(winItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Whim")
        let menu = NSMenu()
        menu.addItem(withTitle: "新建闪念 (⌘⇧J)", action: #selector(toggleQuickCapture), keyEquivalent: "")
        menu.addItem(withTitle: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "立即同步", action: #selector(triggerSync), keyEquivalent: "")
        menu.addItem(withTitle: "导出 Markdown", action: #selector(triggerExport), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "注入示例数据", action: #selector(triggerSeed), keyEquivalent: "")
        menu.addItem(withTitle: "清除示例数据", action: #selector(triggerClearSeed), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Whim", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func setupMainWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 730),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let savedTheme = AppThemeMode(rawValue: UserDefaults.standard.string(forKey: "whim.themeMode") ?? "system") ?? .system
        NSApp.appearance = savedTheme.nsAppearance
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.center()
        win.contentView = NSHostingView(
            rootView: MainContentView(
                vm: vm,
                onOpenQuickCapture: { [weak self] in self?.toggleQuickCapture() },
                onToggleWindowPin: { [weak self] pinned in
                    self?.mainWindow?.level = pinned ? .floating : .normal
                }
            )
        )
        win.makeKeyAndOrderFront(nil)
        mainWindow = win
    }

    @objc func toggleQuickCapture() {
        if let panel = quickPanel {
            if panel.isVisible {
                panel.orderOut(nil)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = QuickCapturePanel(vm: vm) { [weak self] in
            self?.quickPanel?.orderOut(nil)
        }
        quickPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func triggerSync() { vm.syncNow() }
    @objc func triggerExport() { vm.exportMarkdown() }
    @objc func triggerSeed() { vm.seedSampleNotes() }
    @objc func triggerClearSeed() { vm.clearSampleNotes() }
}

@main
struct WhimEntry {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
