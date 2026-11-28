import AppKit
import SwiftUI
@preconcurrency import UserNotifications

enum SidebarTab: Equatable {
    case all
    case review
    case random
    case archived
    case trash
    case day(String) // YYYY-MM-DD from heatmap click
    case tag(String)
}

struct ReviewReminder: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var label: String = ""
    var hour: Int
    var minute: Int
    var weekdays: Set<Int>
    var enabled: Bool = true

    static let allWeekdays: Set<Int> = Set(1...7)
    static let workdays: Set<Int> = Set([2, 3, 4, 5, 6])
    static let weekends: Set<Int> = Set([1, 7])

    var formattedTime: String {
        String(format: "%02d:%02d", hour, minute)
    }

    var totalMinutes: Int {
        hour * 60 + minute
    }

    var displayTitle: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch hour {
        case 5..<12: return "晨间复盘"
        case 12..<18: return "午后回顾"
        default: return "晚间总结"
        }
    }

    var timeIcon: String {
        switch hour {
        case 5..<11: return "sunrise.fill"
        case 11..<18: return "sun.max.fill"
        default: return "moon.stars.fill"
        }
    }

    var repeatSummary: String {
        if weekdays.count == 7 { return "每天" }
        if weekdays == Self.workdays { return "工作日" }
        if weekdays == Self.weekends { return "周末" }
        let labels: [(Int, String)] = [(2, "一"), (3, "二"), (4, "三"), (5, "四"), (6, "五"), (7, "六"), (1, "日")]
        let picked = labels.filter { weekdays.contains($0.0) }.map(\.1).joined(separator: "、")
        return picked.isEmpty ? "不重复" : "周\(picked)"
    }

    var notificationBody: String {
        switch hour {
        case 5..<12:
            return "早安，花 2 分钟回顾一下昨天的闪念与思考，带着清晰开始今天。"
        case 12..<18:
            return "小憩片刻，翻看今天记录的灵感，理顺接下来的思路。"
        default:
            return "花 2 分钟回顾今天记录的闪念，整理关键想法。"
        }
    }
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
    @Published var isScanningLAN: Bool = false
    @Published var isPairingDevice: Bool = false
    @Published var isCheckingSyncHealth: Bool = false
    @Published var syncHealth: WhimSyncHealthStatus = .initial
    @Published var peerStatuses: [WhimPeerSyncStatus] = []
    @Published var pairedPeers: [WhimSyncPeer] = []
    @Published var discoveredPeers: [WhimDiscoveredPeer] = []
    @Published var ignoredPeerIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "whim.sync.ignoredPeers") ?? [])
    @Published var reviewReminders: [ReviewReminder] = WhimStoreVM.loadStoredReminders()
    @Published var reviewNotificationStatus: String = ""
    @Published var filterUntagged: Bool = false
    @Published var filterWithImages: Bool = false
    @Published var filterDateRangeDays: Int = 0
    @Published var localAddr: String = ""
    @Published var backups: [BackupInfo] = []
    @Published var backupStatusMsg: String = ""
    @Published var isBackingUp: Bool = false
    @Published var repliesVersion: Int = 0
    @Published var topPinnedNote: WhimNote? = nil

    private static let remindersStorageKey = "whim.review.reminders.v2"

    private static func loadStoredReminders() -> [ReviewReminder] {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: remindersStorageKey),
           let decoded = try? JSONDecoder().decode([ReviewReminder].self, from: data) {
            return decoded
        }
        let legacyEnabled = ud.object(forKey: "whim.review.enabled") as? Bool ?? true
        let legacyHour = ud.object(forKey: "whim.review.hour") as? Int ?? 21
        let legacyMinute = ud.object(forKey: "whim.review.minute") as? Int ?? 30
        let legacyDays: Set<Int> = {
            if let arr = ud.array(forKey: "whim.review.weekdays") as? [Int], !arr.isEmpty {
                return Set(arr.filter { (1...7).contains($0) })
            }
            return ReviewReminder.allWeekdays
        }()
        let migrated = ReviewReminder(
            label: legacyHour < 12 ? "晨间复盘" : "晚间总结",
            hour: max(0, min(23, legacyHour)),
            minute: max(0, min(59, legacyMinute)),
            weekdays: legacyDays.isEmpty ? ReviewReminder.allWeekdays : legacyDays,
            enabled: legacyEnabled
        )
        return [migrated]
    }

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
            localAddr = (try? CoreBridge.shared.getLocalAddr()) ?? ""
            syncMessage = "局域网监听 :\(port)"
            seedSampleNotesIfEmpty()
            reload()
            scheduleDailyReviewNotification()
            startAutoSyncTimer()
            startSyncHealthMonitor()
            syncNow()
            runBackup(force: false)
        } catch {
            syncMessage = "初始化失败: \(error.localizedDescription)"
        }
    }

    func reload() {
        refreshMetadata()
        refreshTopPinnedNote()
        applyFilter()
    }

    func refreshTopPinnedNote() {
        ioQueue.async { [weak self] in
            let page = try? CoreBridge.shared.listNotesPage(limit: 1)
            let firstPinned = page?.notes.first(where: { $0.pinned && !$0.deleted && !$0.archived })
            if let note = firstPinned {
                ThumbnailCache.shared.prefetch(notes: [note])
            }
            DispatchQueue.main.async { [weak self] in
                self?.topPinnedNote = firstPinned
            }
        }
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
        let untagged = filterUntagged
        let withImages = filterWithImages
        let rangeDays = filterDateRangeDays
        nextCursor = nil
        hasMore = false
        isLoadingMore = false

        if tab == .random {
            reshuffleRandom()
            return
        }

        let rangeFromMs: Int64 = rangeDays > 0
            ? Int64(Calendar.current.date(byAdding: .day, value: -rangeDays, to: Date())!.timeIntervalSince1970 * 1000)
            : 0

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
                    page = try CoreBridge.shared.listNotesPage(
                        query: query,
                        dateFromMs: rangeFromMs,
                        onlyUntagged: untagged,
                        onlyWithImages: withImages,
                        limit: limit
                    )
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
                    page = try CoreBridge.shared.listNotesPage(
                        query: query,
                        dateFromMs: rangeFromMs,
                        onlyArchived: true,
                        onlyUntagged: untagged,
                        onlyWithImages: withImages,
                        limit: limit
                    )
                case .trash:
                    page = try CoreBridge.shared.listNotesPage(
                        query: query,
                        onlyDeleted: true,
                        limit: 200
                    )
                case .tag(let path):
                    page = try CoreBridge.shared.listNotesPage(
                        query: query,
                        tagPrefix: path,
                        dateFromMs: rangeFromMs,
                        onlyWithImages: withImages,
                        limit: limit
                    )
                case .random:
                    page = WhimNotePage(notes: [], hasMore: false, nextCursor: nil)
                }
                ThumbnailCache.shared.prefetch(notes: page.notes)
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
        guard hasMore, !isLoadingMore, let cursor = nextCursor, activeTab != .random, activeTab != .trash else { return }
        isLoadingMore = true
        let gen = filterRequestGen
        let tab = activeTab
        let query = searchQuery
        let revDate = reviewDate
        let limit = pageSize
        let untagged = filterUntagged
        let withImages = filterWithImages
        let rangeDays = filterDateRangeDays
        let rangeFromMs: Int64 = rangeDays > 0
            ? Int64(Calendar.current.date(byAdding: .day, value: -rangeDays, to: Date())!.timeIntervalSince1970 * 1000)
            : 0

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
                    page = try CoreBridge.shared.listNotesPage(
                        query: query,
                        dateFromMs: rangeFromMs,
                        onlyUntagged: untagged,
                        onlyWithImages: withImages,
                        limit: limit,
                        cursor: cursor
                    )
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
                    page = try CoreBridge.shared.listNotesPage(
                        query: query,
                        dateFromMs: rangeFromMs,
                        onlyArchived: true,
                        onlyUntagged: untagged,
                        onlyWithImages: withImages,
                        limit: limit,
                        cursor: cursor
                    )
                case .trash:
                    page = WhimNotePage(notes: [], hasMore: false, nextCursor: nil)
                case .tag(let path):
                    page = try CoreBridge.shared.listNotesPage(
                        query: query,
                        tagPrefix: path,
                        dateFromMs: rangeFromMs,
                        onlyWithImages: withImages,
                        limit: limit,
                        cursor: cursor
                    )
                case .random:
                    page = WhimNotePage(notes: [], hasMore: false, nextCursor: nil)
                }
                ThumbnailCache.shared.prefetch(notes: page.notes)
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
            ThumbnailCache.shared.prefetch(notes: items)
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

    func openDailyReviewToday() {
        activeTab = .review
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
        repliesVersion += 1
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

    var hasQuickFilters: Bool {
        filterUntagged || filterWithImages || filterDateRangeDays > 0
    }

    func resetQuickFilters() {
        filterUntagged = false
        filterWithImages = false
        filterDateRangeDays = 0
        applyFilter()
    }

    func toggleTaskCheckbox(_ note: WhimNote, taskIndex: Int) {
        guard let updated = toggleMarkdownTask(in: note.content, index: taskIndex) else { return }
        editNote(id: note.id, content: updated, attachments: note.attachments ?? [])
    }

    func restoreNote(_ note: WhimNote) {
        _ = try? CoreBridge.shared.updateNote(id: note.id, deleted: false)
        reload()
        syncNow()
    }

    func purgeNote(_ note: WhimNote) {
        try? CoreBridge.shared.purgeNote(id: note.id)
        reload()
    }

    func emptyTrash() {
        _ = try? CoreBridge.shared.purgeOldDeleted(olderThanDays: 0)
        reload()
    }

    func renameTag(oldPrefix: String, newPrefix: String) {
        ioQueue.async { [weak self] in
            let res = try? CoreBridge.shared.renameTag(oldPrefix: oldPrefix, newPrefix: newPrefix)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let res {
                    if case .tag(let current) = self.activeTab, current == res.oldTag || current.hasPrefix(res.oldTag + "/") {
                        let suffix = String(current.dropFirst(res.oldTag.count))
                        self.activeTab = .tag(res.newTag + suffix)
                    }
                    self.syncMessage = "已将 #\(res.oldTag) 迁移为 #\(res.newTag)（更新 \(res.updatedNotes) 条笔记）"
                    self.reload()
                    if res.updatedNotes > 0 { self.syncNow() }
                }
            }
        }
    }

    func loadReplies(parentId: String, completion: @escaping ([WhimNote]) -> Void) {
        ioQueue.async {
            let items = (try? CoreBridge.shared.listReplies(parentId: parentId)) ?? []
            ThumbnailCache.shared.prefetch(notes: items)
            DispatchQueue.main.async { completion(items) }
        }
    }

    func createReply(parentId: String, content: String, attachments: [WhimAttachment] = [], completion: @escaping (WhimNote?) -> Void) {
        ioQueue.async { [weak self] in
            let created = try? CoreBridge.shared.createReply(parentId: parentId, content: content, attachments: attachments)
            DispatchQueue.main.async { [weak self] in
                if created != nil {
                    self?.repliesVersion += 1
                    self?.reload()
                    self?.syncNow()
                }
                completion(created)
            }
        }
    }

    func runBackup(force: Bool) {
        guard !isBackingUp else { return }
        isBackingUp = true
        if force { backupStatusMsg = "正在创建本地备份..." }
        ioQueue.async { [weak self] in
            let res = try? CoreBridge.shared.backupDatabase(keepDays: 7, force: force)
            let list = (try? CoreBridge.shared.listBackups()) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBackingUp = false
                self.backups = list
                if force, let res {
                    self.backupStatusMsg = "备份完成：\(URL(fileURLWithPath: res.backupPath).lastPathComponent)"
                }
            }
        }
    }

    func refreshBackups() {
        ioQueue.async { [weak self] in
            let list = (try? CoreBridge.shared.listBackups()) ?? []
            DispatchQueue.main.async { [weak self] in
                self?.backups = list
            }
        }
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

    private func startSyncHealthMonitor() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var tick = 0
            while self != nil {
                let activeProbe = (tick % 3 == 0)
                tick += 1
                if let health = try? CoreBridge.shared.checkSyncHealth(activeProbe: activeProbe) {
                    DispatchQueue.main.async { [weak self] in
                        self?.syncHealth = health
                    }
                }
                Thread.sleep(forTimeInterval: 6.0)
            }
        }
    }

    func refreshSyncHealth(activeProbe: Bool = true) {
        guard !isCheckingSyncHealth else { return }
        isCheckingSyncHealth = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let health = try? CoreBridge.shared.checkSyncHealth(activeProbe: activeProbe)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isCheckingSyncHealth = false
                if let health {
                    self.syncHealth = health
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
            let health = try? CoreBridge.shared.checkSyncHealth(activeProbe: true)
            let paired = (try? CoreBridge.shared.listPairedPeers()) ?? []
            DispatchQueue.main.async {
                self.isSyncing = false
                self.pairedPeers = paired
                if let health {
                    self.syncHealth = health
                }
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let paired = (try? CoreBridge.shared.listPairedPeers()) ?? []
            DispatchQueue.main.async { [weak self] in
                self?.pairedPeers = paired
            }
        }
    }

    func scanLANPeers() {
        guard !isScanningLAN else { return }
        isScanningLAN = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = (try? CoreBridge.shared.discoverLAN()) ?? []
            let paired = (try? CoreBridge.shared.listPairedPeers()) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isScanningLAN = false
                self.discoveredPeers = found
                self.pairedPeers = paired
            }
        }
    }

    func pairWithDevice(addr: String, remoteCode: String, completion: ((Bool) -> Void)? = nil) {
        guard !isPairingDevice else { return }
        let trimmedAddr = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = String(remoteCode.filter(\.isNumber))
        guard !trimmedAddr.isEmpty, cleanCode.count == 6 else {
            syncMessage = "请输入有效的设备地址和 6 位配对码"
            completion?(false)
            return
        }
        isPairingDevice = true
        syncMessage = "正在连接 \(trimmedAddr) 并验证对方配对码..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let res = try CoreBridge.shared.pairAndSync(addr: trimmedAddr, remoteCode: cleanCode)
                let paired = (try? CoreBridge.shared.listPairedPeers()) ?? []
                let found = (try? CoreBridge.shared.discoverLAN()) ?? []
                let health = try? CoreBridge.shared.checkSyncHealth(activeProbe: true)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isPairingDevice = false
                    self.pairedPeers = paired
                    self.discoveredPeers = found
                    if let health { self.syncHealth = health }
                    self.syncMessage = "配对成功" + (res.notesMerged > 0 ? " · 已合并 \(res.notesMerged) 条笔记" : " · 已保持同步")
                    if res.notesMerged > 0 || res.blobsDownloaded > 0 {
                        self.reload()
                    }
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isPairingDevice = false
                    self.syncMessage = error.localizedDescription
                    completion?(false)
                }
            }
        }
    }

    func forgetPeer(peerId: String, displayName: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try CoreBridge.shared.removePairedPeer(peerId: peerId)
                let paired = (try? CoreBridge.shared.listPairedPeers()) ?? []
                let found = (try? CoreBridge.shared.discoverLAN()) ?? []
                let health = try? CoreBridge.shared.checkSyncHealth(activeProbe: false)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pairedPeers = paired
                    self.discoveredPeers = found
                    if let health { self.syncHealth = health }
                    self.syncMessage = "已断开与「\(displayName.isEmpty ? peerId : displayName)」的连接，双方已停止自动同步"
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.syncMessage = "断开失败: \(error.localizedDescription)"
                }
            }
        }
    }

    func ignoreDiscoveredPeer(peerId: String) {
        guard !peerId.isEmpty else { return }
        ignoredPeerIDs.insert(peerId)
        UserDefaults.standard.set(Array(ignoredPeerIDs), forKey: "whim.sync.ignoredPeers")
    }

    func restoreIgnoredPeers() {
        ignoredPeerIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: "whim.sync.ignoredPeers")
        scanLANPeers()
    }

    func regeneratePairCode() {
        if let updated = try? CoreBridge.shared.regeneratePairCode() {
            pairCode = updated
            syncMessage = "已重新生成本机配对码（不影响已配对的其他电脑）"
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

    static let reviewCategoryId = "WHIM_DAILY_REVIEW"
    static let reviewActionOpen = "WHIM_REVIEW_OPEN"
    static let reviewActionSnooze = "WHIM_REVIEW_SNOOZE"

    var enabledReminders: [ReviewReminder] {
        reviewReminders
            .filter { $0.enabled && !$0.weekdays.isEmpty }
            .sorted { $0.totalMinutes < $1.totalMinutes }
    }

    var hasEnabledReminders: Bool {
        !enabledReminders.isEmpty
    }

    var reviewScheduleSummary: String {
        let active = enabledReminders
        guard !active.isEmpty else { return "提醒已关" }
        if active.count == 1, let r = active.first {
            return "\(r.repeatSummary) \(r.formattedTime)"
        }
        if active.count == 2 {
            return "\(active[0].formattedTime) · \(active[1].formattedTime)"
        }
        return "\(active[0].formattedTime) 等 \(active.count) 个提醒"
    }

    @discardableResult
    func addReminder(
        label: String = "",
        hour: Int = 8,
        minute: Int = 30,
        weekdays: Set<Int> = ReviewReminder.allWeekdays
    ) -> ReviewReminder {
        let item = ReviewReminder(
            label: label,
            hour: max(0, min(23, hour)),
            minute: max(0, min(59, minute)),
            weekdays: weekdays.isEmpty ? ReviewReminder.allWeekdays : weekdays,
            enabled: true
        )
        reviewReminders.append(item)
        reviewReminders.sort { $0.totalMinutes < $1.totalMinutes }
        persistAndScheduleReminders()
        return item
    }

    func updateReminder(_ updated: ReviewReminder) {
        guard let idx = reviewReminders.firstIndex(where: { $0.id == updated.id }) else { return }
        var safe = updated
        if safe.weekdays.isEmpty { safe.weekdays = ReviewReminder.allWeekdays }
        reviewReminders[idx] = safe
        reviewReminders.sort { $0.totalMinutes < $1.totalMinutes }
        persistAndScheduleReminders()
    }

    func toggleReminder(id: String) {
        guard let idx = reviewReminders.firstIndex(where: { $0.id == id }) else { return }
        reviewReminders[idx].enabled.toggle()
        persistAndScheduleReminders()
    }

    func deleteReminder(id: String) {
        reviewReminders.removeAll { $0.id == id }
        persistAndScheduleReminders()
    }

    private func persistAndScheduleReminders() {
        if let data = try? JSONEncoder().encode(reviewReminders) {
            UserDefaults.standard.set(data, forKey: Self.remindersStorageKey)
        }
        scheduleDailyReviewNotification()
    }

    private func registerNotificationCategories(on center: UNUserNotificationCenter) {
        let openAction = UNNotificationAction(identifier: Self.reviewActionOpen, title: "去复盘", options: [.foreground])
        let snoozeAction = UNNotificationAction(identifier: Self.reviewActionSnooze, title: "30 分钟后再提醒", options: [])
        let category = UNNotificationCategory(
            identifier: Self.reviewCategoryId,
            actions: [openAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func scheduleDailyReviewNotification() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        registerNotificationCategories(on: center)
        let active = enabledReminders
        let summary = reviewScheduleSummary

        center.getPendingNotificationRequests { [weak self] existing in
            let toRemove = existing
                .map(\.identifier)
                .filter { id in
                    guard id.hasPrefix("whim.daily.review") else { return false }
                    if active.isEmpty { return true }
                    return id != "whim.daily.review.snooze"
                }
            if !toRemove.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: toRemove)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                guard !active.isEmpty else {
                    self.reviewNotificationStatus = "所有提醒已关闭"
                    return
                }
                center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, err in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let err {
                            self.reviewNotificationStatus = "通知注册失败: \(err.localizedDescription)"
                            return
                        }
                        if !granted {
                            self.reviewNotificationStatus = "系统通知权限未开启，请在「系统设置 → 通知 → Whim」中允许通知"
                            return
                        }

                        for reminder in active {
                            let content = UNMutableNotificationContent()
                            content.title = "\(reminder.displayTitle) · Whim"
                            content.body = reminder.notificationBody
                            content.sound = .default
                            content.categoryIdentifier = Self.reviewCategoryId

                            let days = reminder.weekdays.sorted()
                            if days.count == 7 {
                                var comps = DateComponents()
                                comps.hour = reminder.hour
                                comps.minute = reminder.minute
                                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                                let req = UNNotificationRequest(
                                    identifier: "whim.daily.review.\(reminder.id)",
                                    content: content,
                                    trigger: trigger
                                )
                                center.add(req)
                            } else {
                                for wd in days {
                                    var comps = DateComponents()
                                    comps.hour = reminder.hour
                                    comps.minute = reminder.minute
                                    comps.weekday = wd
                                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                                    let req = UNNotificationRequest(
                                        identifier: "whim.daily.review.\(reminder.id).\(wd)",
                                        content: content,
                                        trigger: trigger
                                    )
                                    center.add(req)
                                }
                            }
                        }
                        self.reviewNotificationStatus = "已生效 \(active.count) 个提醒：\(summary)"
                    }
                }
            }
        }
    }

    func sendTestReviewNotification() {
        guard Bundle.main.bundleIdentifier != nil else {
            reviewNotificationStatus = "请通过 Whim.app 启动以启用系统通知"
            return
        }
        let center = UNUserNotificationCenter.current()
        registerNotificationCategories(on: center)
        let todayCount = dailyCounts[dayFmt.string(from: Date())] ?? 0
        let sampleTitle = enabledReminders.first?.displayTitle ?? "每日复盘"
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let err {
                    self.reviewNotificationStatus = "通知发送失败: \(err.localizedDescription)"
                    return
                }
                if !granted {
                    self.reviewNotificationStatus = "未获得通知权限，请在「系统设置 → 通知 → Whim」开启"
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "\(sampleTitle) · Whim（测试）"
                content.body = todayCount > 0
                    ? "今天已记录 \(todayCount) 条闪念，点击这条通知可直达每日回顾。"
                    : "点击这条通知可直达每日回顾页面，长按/展开还可选择 30 分钟后再提醒。"
                content.sound = .default
                content.categoryIdentifier = Self.reviewCategoryId
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let req = UNNotificationRequest(identifier: "whim.daily.review.test", content: content, trigger: trigger)
                center.add(req) { addErr in
                    DispatchQueue.main.async {
                        self.reviewNotificationStatus = addErr == nil ? "测试通知已发出，请留意右上角系统横幅" : "发送失败: \(addErr!.localizedDescription)"
                    }
                }
            }
        }
    }

    func scheduleSnoozeReviewNotification(minutes: Int = 30) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        registerNotificationCategories(on: center)
        center.removePendingNotificationRequests(withIdentifiers: ["whim.daily.review.snooze"])
        let content = UNMutableNotificationContent()
        content.title = "每日复盘 · Whim"
        content.body = "稍后提醒时间到了，花 2 分钟回顾今天的闪念吧。"
        content.sound = .default
        content.categoryIdentifier = Self.reviewCategoryId
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(1, minutes) * 60), repeats: false)
        let req = UNNotificationRequest(identifier: "whim.daily.review.snooze", content: content, trigger: trigger)
        center.add(req)
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
                .frame(height: editingNote != nil ? 340 : ((!attachments.isEmpty || markdown.count > 160) ? 300 : (isFocused || !markdown.isEmpty ? 180 : 72)))
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
                                    .padding(.vertical, 3.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(active ? FlomoPalette.accent(scheme) : FlomoPalette.tagBg(scheme))
                                    )
                                    .whimClickable(cornerRadius: 5, hoverFill: false)
                            }
                            .buttonStyle(WhimTactileButtonStyle(cornerRadius: 5))
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                toolbarIcon("number", help: "插入标签 (#)") {
                    editor.insertSnippet(markdown.isEmpty || markdown.hasSuffix(" ") || markdown.hasSuffix("\n") ? "#" : " #")
                    editor.focus()
                }
                toolbarIcon("photo", help: "从本地选择图片插入光标处（剪贴板图片直接 ⌘V）") {
                    editor.pickImageFromFinder()
                }

                Spacer()

                if let onFinishEdit {
                    Button(action: onFinishEdit) {
                        Text("取消")
                            .font(.system(size: 12))
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .whimClickable(cornerRadius: 6, hoverFill: true)
                    }
                    .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
                }

                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(canSubmit ? 1.0 : 0.45))
                        .frame(width: 40, height: 27)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(FlomoPalette.accent(scheme).opacity(canSubmit ? 1.0 : 0.45))
                        )
                        .whimClickable(cornerRadius: 6, hoverFill: false)
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
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
                .frame(width: 28, height: 26)
                .whimClickable(cornerRadius: 6, hoverFill: true)
        }
        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
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
    @ObservedObject private var updater = GitHubUpdater.shared
    @State private var showSettingsSheet: Bool = false
    @State private var settingsInitialSection: SettingsSection = .general
    @State private var lightboxState: ImageLightboxState? = nil
    @State private var threadParentNote: WhimNote? = nil
    @State private var renamingTagPath: String? = nil
    @State private var showEmptyTrashConfirm: Bool = false
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
                        navRow(icon: "trash", title: "最近删除", active: vm.activeTab == .trash) {
                            vm.activeTab = .trash
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
                                FlomoTagRow(
                                    node: node,
                                    depth: 0,
                                    activeTab: vm.activeTab,
                                    onSelect: { path in
                                        vm.activeTab = .tag(path)
                                        vm.applyFilter()
                                    },
                                    onRenameTag: { path in
                                        renamingTagPath = path
                                    }
                                )
                            }
                        }
                    }

                    Divider().opacity(0.25)
                    HStack(spacing: 8) {
                        Button {
                            settingsInitialSection = updater.hasUpdate ? .about : .general
                            showSettingsSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 12))
                                Text("设置")
                                    .font(.system(size: 12, weight: .medium))
                                if updater.hasUpdate {
                                    Circle()
                                        .fill(Color(hex: 0xEF4444))
                                        .frame(width: 6.5, height: 6.5)
                                }
                            }
                            .foregroundColor(FlomoPalette.textSecondary(scheme))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .whimClickable(cornerRadius: 7, hoverFill: true)
                        }
                        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
                        .help(updater.hasUpdate ? "发现新版本 \(updater.latestRelease?.tagName ?? "")，点击查看更新" : "打开偏好设置 (⌘,)")

                        Spacer()

                        Button {
                            if vm.syncHealth.state == "unpaired" || vm.syncHealth.state == "wrong_code" {
                                settingsInitialSection = .sync
                                showSettingsSheet = true
                            } else {
                                vm.syncNow()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(syncStatusDotColor)
                                    .frame(width: 6.5, height: 6.5)
                                Text(syncStatusLabel)
                                    .font(.system(size: 11.5, weight: vm.syncHealth.connected ? .medium : .regular).monospacedDigit())
                                    .foregroundColor(syncStatusTextColor)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(vm.syncHealth.connected ? FlomoPalette.accent(scheme).opacity(0.16) : FlomoPalette.border(scheme).opacity(0.7))
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 12))
                        .whimClickable(cornerRadius: 12, hoverFill: false)
                        .disabled(vm.isSyncing)
                        .help(syncStatusTooltip)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .frame(width: 248)
                .background(FlomoPalette.sidebar(scheme))

                // Right Main Column
                VStack(alignment: .leading, spacing: 14) {
                    // Top Bar: Title + Search (⌘K) + Pin + Utility Menu
                    HStack(spacing: 10) {
                        Text(currentTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(FlomoPalette.textPrimary(scheme))

                        if case .day = vm.activeTab {
                            Button {
                                vm.activeTab = .all
                                vm.applyFilter()
                            } label: {
                                Text("清除日期")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(FlomoPalette.tagText(scheme))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .whimClickable(cornerRadius: 6, hoverFill: true)
                            }
                            .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
                        }

                        if vm.activeTab == .trash && !vm.displayedNotes.isEmpty {
                            WhimSecondaryButton(title: "清空回收站", icon: "trash", destructive: true, compact: true) {
                                showEmptyTrashConfirm = true
                            }
                            .alert("清空最近删除？", isPresented: $showEmptyTrashConfirm) {
                                Button("取消", role: .cancel) {}
                                Button("彻底清空", role: .destructive) {
                                    vm.emptyTrash()
                                }
                            } message: {
                                Text("回收站中的所有笔记将被永久删除，无法恢复。")
                            }
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
                                        .font(.system(size: 12))
                                        .foregroundColor(FlomoPalette.textMuted(scheme))
                                        .frame(width: 20, height: 20)
                                        .whimClickable(cornerRadius: 10, hoverFill: false)
                                }
                                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 10))
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
                                .frame(width: 28, height: 28)
                                .whimClickable(cornerRadius: 7, hoverFill: true)
                        }
                        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
                        .help(mainWindowPinned ? "取消主窗口置顶" : "主窗口置顶")

                        Button {
                            vm.syncNow()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12.5))
                                .foregroundColor(vm.isSyncing ? FlomoPalette.accent(scheme) : FlomoPalette.textSecondary(scheme))
                                .frame(width: 28, height: 28)
                                .whimClickable(cornerRadius: 7, hoverFill: true)
                        }
                        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
                        .disabled(vm.isSyncing)
                        .help("立即局域网同步")

                        Button(action: onOpenQuickCapture) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12.5))
                                .foregroundColor(FlomoPalette.textSecondary(scheme))
                                .frame(width: 28, height: 28)
                                .whimClickable(cornerRadius: 7, hoverFill: true)
                        }
                        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
                        .help("新建浮窗 (⌘⇧J)")
                    }
                    .padding(.top, 14)
                    .padding(.horizontal, 10)

                    // Quick Filter Bar (All / Tag / Archived)
                    if vm.activeTab == .all || vm.activeTab == .archived || { if case .tag = vm.activeTab { return true }; return false }() {
                        quickFilterBar
                            .padding(.horizontal, 10)
                    }

                    if vm.activeTab == .review || vm.activeTab == .random {
                        VStack(spacing: 14) {
                            if vm.activeTab == .review {
                                dailyReviewBar
                            } else {
                                randomWalkBar
                            }
                            FlomoCardDeckView(
                                vm: vm,
                                notes: vm.displayedNotes,
                                isRandomMode: vm.activeTab == .random,
                                resetKey: "\(vm.activeTab)|\(vm.dayFmt.string(from: vm.reviewDate))|\(vm.displayedNotes.first?.id ?? "")|\(vm.displayedNotes.count)",
                                editingNoteId: $editingNoteId,
                                searchFocused: searchFocused,
                                onTapTag: { path in
                                    vm.activeTab = .tag(path)
                                    vm.applyFilter()
                                },
                                onTapImages: { paths, idx in lightboxState = ImageLightboxState(paths: paths, initialIndex: idx) },
                                onOpenThread: { note in threadParentNote = note },
                                onReshuffle: { vm.reshuffleRandom() }
                            )
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                    // Note Card Feed (NSTableView-backed List for true cell recycling & 120Hz scrolling)
                    ScrollViewReader { scrollProxy in
                        List {
                            Color.clear
                                .frame(height: 0)
                                .id("__feed_top__")
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())

                            if vm.activeTab != .archived && vm.activeTab != .trash {
                                FlomoComposerView(vm: vm)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 4))
                            }

                            if vm.displayedNotes.isEmpty {
                                VStack(spacing: 8) {
                                    Text(
                                        vm.activeTab == .trash
                                            ? "最近删除为空"
                                            : (vm.searchQuery.isEmpty ? "暂无记录" : "未找到匹配“\(vm.searchQuery)”的笔记")
                                    )
                                        .font(.system(size: 14))
                                        .foregroundColor(FlomoPalette.textMuted(scheme))
                                    if vm.activeTab == .trash {
                                        Text("删除的笔记会保留在这里，可随时恢复或彻底清理")
                                            .font(.system(size: 12))
                                            .foregroundColor(FlomoPalette.textMuted(scheme))
                                    } else if vm.searchQuery.isEmpty && !vm.hasQuickFilters {
                                        Text("在上方输入框记下想法（支持 ⌘V 光标处贴图），或随时按 ⌘⇧J 呼出悬浮速记")
                                            .font(.system(size: 12))
                                            .foregroundColor(FlomoPalette.textMuted(scheme))
                                    } else {
                                        Button("清除搜索与筛选") {
                                            vm.searchQuery = ""
                                            vm.resetQuickFilters()
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
                                        if editingNoteId == note.id && vm.activeTab != .trash {
                                            FlomoComposerView(vm: vm, editingNote: note) {
                                                editingNoteId = nil
                                            }
                                        } else {
                                            FlomoNoteCard(
                                                note: note,
                                                highlightQuery: vm.searchQuery,
                                                isTrashMode: vm.activeTab == .trash,
                                                repliesVersion: vm.repliesVersion,
                                                onLoadReplies: { completion in vm.loadReplies(parentId: note.id, completion: completion) },
                                                onTapTag: { path in
                                                    vm.activeTab = .tag(path)
                                                    vm.applyFilter()
                                                },
                                                onTapImages: { paths, idx in lightboxState = ImageLightboxState(paths: paths, initialIndex: idx) },
                                                onToggleTask: { taskIdx in vm.toggleTaskCheckbox(note, taskIndex: taskIdx) },
                                                onOpenThread: { threadParentNote = note },
                                                onEdit: { editingNoteId = note.id },
                                                onPin: { vm.togglePin(note) },
                                                onArchive: { vm.toggleArchive(note) },
                                                onDelete: { vm.deleteNote(note) },
                                                onRestore: { vm.restoreNote(note) },
                                                onPurge: { vm.purgeNote(note) }
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
                }
                .padding(.horizontal, 12)
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
            Button("") {
                settingsInitialSection = .general
                showSettingsSheet = true
            }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .frame(minWidth: 880, minHeight: 620)
        .background(FlomoPalette.canvas(scheme))
        .preferredColorScheme((AppThemeMode(rawValue: themeModeRaw) ?? .system).colorScheme)
        .onAppear {
            GitHubUpdater.shared.silentCheckOnLaunch()
        }
        .sheet(item: $lightboxState) { state in
            ImageLightboxView(paths: state.paths, initialIndex: state.initialIndex) {
                lightboxState = nil
            }
        }
        .sheet(item: $threadParentNote) { parent in
            NoteThreadSheet(
                vm: vm,
                parentNote: parent,
                onTapTag: { path in
                    threadParentNote = nil
                    vm.activeTab = .tag(path)
                    vm.applyFilter()
                },
                onTapImages: { paths, idx in
                    lightboxState = ImageLightboxState(paths: paths, initialIndex: idx)
                },
                onClose: { threadParentNote = nil }
            )
        }
        .sheet(isPresented: Binding(get: { renamingTagPath != nil }, set: { if !$0 { renamingTagPath = nil } })) {
            if let tagPath = renamingTagPath {
                TagRenameSheet(
                    oldTag: tagPath,
                    onConfirm: { newPath in
                        renamingTagPath = nil
                        vm.renameTag(oldPrefix: tagPath, newPrefix: newPath)
                    },
                    onCancel: { renamingTagPath = nil }
                )
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
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(FlomoPalette.canvas(scheme)))
                    .whimClickable(cornerRadius: 7, hoverFill: true)
            }
            .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))

            Text(isToday ? "\(dateText) · 今天" : dateText)
                .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                .foregroundColor(FlomoPalette.textPrimary(scheme))

            Button { vm.shiftReviewDay(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isToday ? FlomoPalette.textMuted(scheme) : FlomoPalette.textPrimary(scheme))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(FlomoPalette.canvas(scheme)))
                    .whimClickable(cornerRadius: 7, hoverFill: !isToday)
            }
            .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
            .disabled(isToday)

            if !isToday {
                Button { vm.jumpReviewToday() } label: {
                    Text("回到今天")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(FlomoPalette.tagText(scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .whimClickable(cornerRadius: 6, hoverFill: true)
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
            }

            Spacer()

            Text("当日共 \(vm.displayedNotes.count) 条记录")
                .font(.system(size: 12))
                .foregroundColor(FlomoPalette.textSecondary(scheme))

            Button {
                settingsInitialSection = .review
                showSettingsSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: vm.hasEnabledReminders ? "bell.fill" : "bell.slash")
                        .font(.system(size: 10.5))
                    Text(vm.reviewScheduleSummary)
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                }
                .foregroundColor(vm.hasEnabledReminders ? FlomoPalette.tagText(scheme) : FlomoPalette.textMuted(scheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(vm.hasEnabledReminders ? FlomoPalette.tagBg(scheme) : FlomoPalette.canvas(scheme))
                )
                .whimClickable(cornerRadius: 7, hoverFill: false)
            }
            .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
            .help("管理每日复盘与总结提醒时钟")
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
            WhimPrimaryButton(title: "换一批", icon: "shuffle", compact: true) {
                vm.reshuffleRandom()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FlomoPalette.card(scheme)))
    }

    private var syncStatusDotColor: Color {
        if vm.isSyncing || vm.isCheckingSyncHealth { return Color(hex: 0xF59E0B) }
        if vm.syncHealth.connected { return Color(hex: 0x34D399) }
        if vm.syncHealth.state == "wrong_code" { return Color(hex: 0xF59E0B) }
        return FlomoPalette.textMuted(scheme)
    }

    private var syncStatusTextColor: Color {
        if vm.syncHealth.connected { return Color(hex: 0x34D399) }
        if vm.syncHealth.state == "wrong_code" { return Color(hex: 0xF59E0B) }
        return FlomoPalette.textMuted(scheme)
    }

    private var syncStatusLabel: String {
        if vm.isSyncing { return "同步中" }
        if vm.syncHealth.connected {
            return vm.syncHealth.rttMs > 0 ? "已同步 · \(vm.syncHealth.rttMs)ms" : "已同步"
        }
        switch vm.syncHealth.state {
        case "wrong_code": return "配对码错"
        case "unpaired": return "未配对"
        default: return "未连接"
        }
    }

    private var syncStatusTooltip: String {
        if vm.isSyncing { return "正在进行双向同步与心跳探测..." }
        if vm.syncHealth.connected {
            let name = vm.syncHealth.peerName ?? "局域网设备"
            return "实时心跳正常：\(name)（\(vm.syncHealth.onlinePeers) 台在线 · 延迟 \(vm.syncHealth.rttMs)ms）· 点击立即同步"
        }
        switch vm.syncHealth.state {
        case "wrong_code": return "局域网设备配对码不匹配 · 点击打开同步设置"
        case "unpaired": return "尚未配置配对码 · 点击打开同步设置"
        default: return "当前无在线设备响应心跳 · 点击立即 Ping 检测并同步"
        }
    }

    private var quickFilterBar: some View {
        let isTagTab: Bool = { if case .tag = vm.activeTab { return true }; return false }()
        return HStack(spacing: 8) {
            if !isTagTab {
                filterPill("无标签", active: vm.filterUntagged) {
                    vm.filterUntagged.toggle()
                    vm.applyFilter()
                }
            }
            filterPill("含图片", active: vm.filterWithImages) {
                vm.filterWithImages.toggle()
                vm.applyFilter()
            }
            filterPill("近 7 天", active: vm.filterDateRangeDays == 7) {
                vm.filterDateRangeDays = vm.filterDateRangeDays == 7 ? 0 : 7
                vm.applyFilter()
            }
            filterPill("近 30 天", active: vm.filterDateRangeDays == 30) {
                vm.filterDateRangeDays = vm.filterDateRangeDays == 30 ? 0 : 30
                vm.applyFilter()
            }
            if vm.hasQuickFilters {
                Button {
                    vm.resetQuickFilters()
                } label: {
                    Text("重置")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(FlomoPalette.tagText(scheme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func filterPill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : FlomoPalette.textSecondary(scheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(
                    Capsule()
                        .fill(active ? FlomoPalette.accent(scheme) : FlomoPalette.card(scheme))
                )
                .overlay(
                    Capsule()
                        .stroke(active ? Color.clear : FlomoPalette.border(scheme), lineWidth: 0.8)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 12))
        .whimClickable(cornerRadius: 12, hoverFill: false)
    }

    private var currentTitle: String {
        switch vm.activeTab {
        case .all: return "全部笔记"
        case .review: return "每日回顾"
        case .random: return "随机漫步"
        case .archived: return "已归档"
        case .trash: return "最近删除"
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
        SidebarNavButton(icon: icon, title: title, active: active, badge: badge, action: action)
    }
}

private struct SidebarNavButton: View {
    @Environment(\.colorScheme) private var scheme
    let icon: String
    let title: String
    let active: Bool
    var badge: String? = nil
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
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
                        .foregroundColor(active ? .white.opacity(0.85) : FlomoPalette.textMuted(scheme))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? FlomoPalette.accent(scheme) : (isHovered ? FlomoPalette.hoverFill(scheme) : .clear))
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

private struct FlomoTagRow: View {
    @Environment(\.colorScheme) private var scheme
    let node: WhimTagNode
    let depth: Int
    let activeTab: SidebarTab
    let onSelect: (String) -> Void
    var onRenameTag: ((String) -> Void)? = nil

    @State private var expanded: Bool = true
    @State private var isHovered: Bool = false

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
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(WhimTactileButtonStyle(cornerRadius: 4, pressScale: 0.95))
                } else {
                    Spacer().frame(width: 18)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6, pressScale: 0.99))
            }
            .padding(.leading, CGFloat(depth * 12) + 4)
            .padding(.trailing, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? FlomoPalette.accent(scheme) : (isHovered ? FlomoPalette.hoverFill(scheme) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contextMenu {
                Button("重命名 / 合并标签...") {
                    onRenameTag?(node.fullPath)
                }
            }
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHovered { isHovered = false; NSCursor.pop() }
            }

            if expanded, let children = node.children {
                ForEach(children) { child in
                    FlomoTagRow(node: child, depth: depth + 1, activeTab: activeTab, onSelect: onSelect, onRenameTag: onRenameTag)
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

    private let displaySize: CGSize
    @State private var image: NSImage?

    init(path: String, onTap: @escaping (String) -> Void) {
        self.path = path
        self.onTap = onTap
        self.displaySize = ThumbnailCache.shared.fittedDisplaySize(forPath: path, maxWidth: 460, maxHeight: 280)
        _image = State(initialValue: ThumbnailCache.shared.cachedImage(forPath: path))
    }

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(FlomoPalette.border(scheme), lineWidth: 0.8)
                    )
                    .padding(.vertical, 3)
                    .onTapGesture { onTap(path) }
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FlomoPalette.canvas(scheme))
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(FlomoPalette.border(scheme), lineWidth: 0.8)
                    )
                    .padding(.vertical, 3)
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
    var onOpenThread: (() -> Void)? = nil
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
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(editHovered ? FlomoPalette.hoverFill(scheme) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(WhimTactileButtonStyle(cornerRadius: 5))
            .onHover { hovering in
                editHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if editHovered { editHovered = false; NSCursor.pop() }
            }
            .help("编辑笔记")

            Menu {
                Button("编辑", action: onEdit)
                if let onOpenThread {
                    Button("添加 / 查看追记", action: onOpenThread)
                }
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
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(menuHovered ? FlomoPalette.hoverFill(scheme) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .onHover { hovering in
                menuHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if menuHovered { menuHovered = false; NSCursor.pop() }
            }
        }
    }
}

struct FlomoNoteCardBody: View, Equatable {
    @Environment(\.colorScheme) private var scheme
    let noteId: String
    let updatedAt: Int64
    let content: String
    let attachments: [WhimAttachment]
    var highlightQuery: String = ""
    let onTapTag: (String) -> Void
    let onTapImages: ([String], Int) -> Void
    var onToggleTask: ((Int) -> Void)? = nil

    static func == (lhs: FlomoNoteCardBody, rhs: FlomoNoteCardBody) -> Bool {
        lhs.noteId == rhs.noteId &&
        lhs.updatedAt == rhs.updatedAt &&
        lhs.content == rhs.content &&
        lhs.attachments == rhs.attachments &&
        lhs.highlightQuery == rhs.highlightQuery
    }

    var body: some View {
        let cacheKey = "\(noteId):\(updatedAt):\(attachments.count):inline"
        let blocks = NoteContentParser.parseCached(
            cacheKey: cacheKey,
            content: content,
            attachments: attachments,
            stripTags: []
        )
        let allImagePaths: [String] = blocks.compactMap {
            if case .image(_, _, let p) = $0 { return p }
            return nil
        }
        let indexedBlocks: [(block: NoteContentBlock, taskOffset: Int, imageIdx: Int)] = {
            var tOff = 0
            var imgIdx = 0
            var res: [(NoteContentBlock, Int, Int)] = []
            for b in blocks {
                switch b {
                case .text(_, let val):
                    res.append((b, tOff, imgIdx))
                    tOff += countMarkdownTasks(in: val)
                case .image:
                    res.append((b, tOff, imgIdx))
                    imgIdx += 1
                }
            }
            return res
        }()
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(indexedBlocks.enumerated()), id: \.offset) { _, entry in
                switch entry.block {
                case .text(_, let val):
                    MarkdownBlockView(
                        text: val,
                        highlightQuery: highlightQuery,
                        taskOffset: entry.taskOffset,
                        onTapTag: onTapTag,
                        onToggleTask: onToggleTask
                    )
                    .equatable()
                case .image(_, _, let path):
                    AsyncCardImage(path: path) { _ in
                        onTapImages(allImagePaths.isEmpty ? [path] : allImagePaths, entry.imageIdx)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlomoNoteCard: View {
    @Environment(\.colorScheme) private var scheme
    let note: WhimNote
    var highlightQuery: String = ""
    var isTrashMode: Bool = false
    var repliesVersion: Int = 0
    var onLoadReplies: ((@escaping ([WhimNote]) -> Void) -> Void)? = nil
    let onTapTag: (String) -> Void
    let onTapImages: ([String], Int) -> Void
    var onToggleTask: ((Int) -> Void)? = nil
    var onOpenThread: (() -> Void)? = nil
    let onEdit: () -> Void
    let onPin: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    var onRestore: (() -> Void)? = nil
    var onPurge: (() -> Void)? = nil

    @State private var expanded: Bool = false
    @State private var naturalHeight: CGFloat = 0
    @State private var inlineReplies: [WhimNote] = []
    @State private var loadingReplies: Bool = false

    private static let maxCollapsedHeight: CGFloat = 340

    private static let cardTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func formatMs(_ ms: Int64) -> String {
        Self.cardTimeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0))
    }

    private var formattedTime: String {
        formatMs(note.createdAt)
    }

    private var needsCollapse: Bool {
        naturalHeight > Self.maxCollapsedHeight + 16
    }

    private func loadInlineRepliesIfNeeded() {
        let count = note.replyCount ?? 0
        guard expanded, !isTrashMode, count > 0, let onLoadReplies else {
            if count == 0 { inlineReplies = [] }
            return
        }
        loadingReplies = true
        onLoadReplies { items in
            self.inlineReplies = items
            self.loadingReplies = false
        }
    }

    var body: some View {
        let isCollapsed = needsCollapse && !expanded
        let replyCount = note.replyCount ?? 0
        let hasReplies = !isTrashMode && replyCount > 0
        let canExpand = needsCollapse || hasReplies
        let expandTitle: String = {
            if expanded {
                return needsCollapse ? "收起" : "收起追记"
            }
            if needsCollapse && hasReplies {
                return "展开全文 · 含 \(replyCount) 条追记"
            }
            if needsCollapse {
                return "展开全文"
            }
            return "展开 \(replyCount) 条追记"
        }()
        VStack(alignment: .leading, spacing: 10) {
            // Meta header row
            HStack(spacing: 6) {
                Text(note.pinned && !isTrashMode ? "置顶 · \(formattedTime)" : formattedTime)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(FlomoPalette.textSecondary(scheme))
                Spacer()
                if isTrashMode {
                    HStack(spacing: 8) {
                        WhimSecondaryButton(title: "恢复", icon: "arrow.uturn.backward", compact: true) {
                            onRestore?()
                        }
                        WhimSecondaryButton(title: "彻底删除", destructive: true, compact: true) {
                            onPurge?()
                        }
                    }
                } else {
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
            }

            FlomoNoteCardBody(
                noteId: note.id,
                updatedAt: note.updatedAt,
                content: note.content,
                attachments: note.attachments ?? [],
                highlightQuery: highlightQuery,
                onTapTag: onTapTag,
                onTapImages: onTapImages,
                onToggleTask: isTrashMode ? nil : onToggleTask
            )
            .equatable()
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            if abs(naturalHeight - geo.size.height) > 2 {
                                naturalHeight = geo.size.height
                            }
                        }
                        .onChange(of: geo.size.height) { _, h in
                            if abs(naturalHeight - h) > 2 {
                                naturalHeight = h
                            }
                        }
                }
            )
            .frame(maxHeight: isCollapsed ? Self.maxCollapsedHeight : nil, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                if isCollapsed {
                    LinearGradient(
                        colors: [FlomoPalette.card(scheme).opacity(0), FlomoPalette.card(scheme)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 52)
                    .allowsHitTesting(false)
                }
            }

            // Inline replies section shown directly inside the card when expanded
            if expanded && hasReplies {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble.fill")
                                .font(.system(size: 10))
                            Text("追记 · \(replyCount) 条")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(FlomoPalette.accent(scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(FlomoPalette.accentSoft(scheme))
                        )
                        Rectangle()
                            .fill(FlomoPalette.border(scheme).opacity(0.7))
                            .frame(height: 1)
                    }
                    .padding(.top, 4)

                    if loadingReplies && inlineReplies.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在加载追记...")
                                .font(.system(size: 11.5))
                                .foregroundColor(FlomoPalette.textMuted(scheme))
                        }
                        .padding(.vertical, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(inlineReplies.enumerated()), id: \.element.id) { idx, reply in
                                HStack(alignment: .top, spacing: 10) {
                                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                        .fill(FlomoPalette.accent(scheme).opacity(0.65))
                                        .frame(width: 2.5)
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
                                                .font(.system(size: 11).monospacedDigit())
                                                .foregroundColor(FlomoPalette.textMuted(scheme))
                                            Spacer()
                                        }
                                        FlomoNoteCardBody(
                                            noteId: reply.id,
                                            updatedAt: reply.updatedAt,
                                            content: reply.content,
                                            attachments: reply.attachments ?? [],
                                            highlightQuery: highlightQuery,
                                            onTapTag: onTapTag,
                                            onTapImages: onTapImages
                                        )
                                        .equatable()
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(FlomoPalette.canvas(scheme).opacity(0.55))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(FlomoPalette.border(scheme).opacity(0.55), lineWidth: 0.5)
                                    )
                                }
                            }
                        }
                    }
                }
                .transition(.opacity)
            }

            HStack(spacing: 12) {
                if canExpand {
                    Button(expandTitle) {
                        expanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(FlomoPalette.tagText(scheme))
                }
                Spacer()
                if !isTrashMode, let onOpenThread {
                    Button(action: onOpenThread) {
                        HStack(spacing: 4) {
                            Image(systemName: replyCount > 0 ? "text.bubble.fill" : "text.bubble")
                                .font(.system(size: 11))
                            Text(replyCount > 0 ? "写追记 (\(replyCount))" : "追记")
                                .font(.system(size: 11.5, weight: replyCount > 0 ? .medium : .regular))
                        }
                        .foregroundColor(replyCount > 0 ? FlomoPalette.accent(scheme) : FlomoPalette.textMuted(scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule().fill(replyCount > 0 ? FlomoPalette.accentSoft(scheme) : Color.clear)
                        )
                        .whimClickable(cornerRadius: 10, hoverFill: replyCount == 0)
                    }
                    .buttonStyle(WhimTactileButtonStyle(cornerRadius: 10))
                }
            }
        }
        .onChange(of: expanded) { _, isExp in
            if isExp { loadInlineRepliesIfNeeded() }
        }
        .onChange(of: repliesVersion) { _, _ in
            if expanded { loadInlineRepliesIfNeeded() }
        }
        .onChange(of: note.replyCount) { _, newCount in
            if (newCount ?? 0) == 0 {
                inlineReplies = []
            } else if expanded {
                loadInlineRepliesIfNeeded()
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
        .onTapGesture(count: 2) {
            if !isTrashMode { onEdit() }
        }
        .contextMenu {
            if isTrashMode {
                Button("恢复笔记") { onRestore?() }
                Divider()
                Button("彻底删除", role: .destructive) { onPurge?() }
            } else {
                Button("编辑", action: onEdit)
                if let onOpenThread {
                    Button("添加 / 查看追记", action: onOpenThread)
                }
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
}

// MARK: - Stacked Swipeable Card Gallery (Daily Review & Random Walk)

private struct DeckCardItemView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: WhimStoreVM
    let note: WhimNote
    let isTop: Bool
    @Binding var editingNoteId: String?
    let onTapTag: (String) -> Void
    let onTapImages: ([String], Int) -> Void
    let onOpenThread: (WhimNote) -> Void

    @State private var inlineReplies: [WhimNote] = []
    @State private var loadingReplies: Bool = false

    private static let cardTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func formattedTime(_ ms: Int64) -> String {
        Self.cardTimeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0))
    }

    private func loadRepliesIfNeeded() {
        let count = note.replyCount ?? 0
        guard isTop, count > 0 else {
            if count == 0 { inlineReplies = [] }
            return
        }
        loadingReplies = true
        vm.loadReplies(parentId: note.id) { items in
            self.inlineReplies = items
            self.loadingReplies = false
        }
    }

    var body: some View {
        let replyCount = note.replyCount ?? 0
        let hasReplies = replyCount > 0

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(note.pinned ? "置顶 · \(formattedTime(note.createdAt))" : formattedTime(note.createdAt))
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundColor(FlomoPalette.textSecondary(scheme))

                if hasReplies {
                    Button { onOpenThread(note) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble.fill")
                                .font(.system(size: 10))
                            Text("含 \(replyCount) 条追记")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(FlomoPalette.accent(scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(FlomoPalette.accentSoft(scheme))
                        )
                        .overlay(
                            Capsule().stroke(FlomoPalette.accent(scheme).opacity(0.35), lineWidth: 0.8)
                        )
                        .whimClickable(cornerRadius: 10, hoverFill: false)
                    }
                    .buttonStyle(WhimTactileButtonStyle(cornerRadius: 10))
                    .disabled(!isTop)
                }

                Spacer()

                if isTop {
                    CardHeaderActions(
                        pinned: note.pinned,
                        archived: note.archived,
                        content: note.content,
                        onOpenThread: { onOpenThread(note) },
                        onEdit: { editingNoteId = note.id },
                        onPin: { vm.togglePin(note) },
                        onArchive: { vm.toggleArchive(note) },
                        onDelete: { vm.deleteNote(note) }
                    )
                }
            }

            Divider().opacity(0.25)

            if editingNoteId == note.id && isTop {
                FlomoComposerView(vm: vm, editingNote: note) {
                    editingNoteId = nil
                }
            } else {
                ScrollView(showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        FlomoNoteCardBody(
                            noteId: note.id,
                            updatedAt: note.updatedAt,
                            content: note.content,
                            attachments: note.attachments ?? [],
                            onTapTag: onTapTag,
                            onTapImages: onTapImages,
                            onToggleTask: { taskIdx in vm.toggleTaskCheckbox(note, taskIndex: taskIdx) }
                        )
                        .equatable()

                        if hasReplies {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "text.bubble.fill")
                                            .font(.system(size: 10))
                                        Text("追记 · \(replyCount) 条")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .foregroundColor(FlomoPalette.accent(scheme))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(FlomoPalette.accentSoft(scheme))
                                    )
                                    .overlay(
                                        Capsule().stroke(FlomoPalette.accent(scheme).opacity(0.35), lineWidth: 0.8)
                                    )
                                    Rectangle()
                                        .fill(FlomoPalette.accent(scheme).opacity(0.26))
                                        .frame(height: 1)
                                }
                                .padding(.top, 4)

                                if loadingReplies && inlineReplies.isEmpty {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("正在加载追记...")
                                            .font(.system(size: 11.5))
                                            .foregroundColor(FlomoPalette.textMuted(scheme))
                                    }
                                    .padding(.vertical, 4)
                                } else {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(inlineReplies.enumerated()), id: \.element.id) { idx, reply in
                                            HStack(alignment: .top, spacing: 10) {
                                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                                    .fill(FlomoPalette.accent(scheme).opacity(0.75))
                                                    .frame(width: 3)
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
                                                        Text(formattedTime(reply.createdAt))
                                                            .font(.system(size: 11).monospacedDigit())
                                                            .foregroundColor(FlomoPalette.textMuted(scheme))
                                                        Spacer()
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
                                                .padding(11)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                        .fill(FlomoPalette.canvas(scheme).opacity(0.65))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                        .stroke(FlomoPalette.accent(scheme).opacity(0.22), lineWidth: 0.7)
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }

                if isTop {
                    Divider().opacity(0.25)
                    HStack(spacing: 10) {
                        if hasReplies {
                            Text("共 \(replyCount) 条追记 · 向下滚动查看")
                                .font(.system(size: 11.5))
                                .foregroundColor(FlomoPalette.textMuted(scheme))
                        }
                        Spacer()
                        Button { onOpenThread(note) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: hasReplies ? "text.bubble.fill" : "text.bubble")
                                    .font(.system(size: 11))
                                Text(hasReplies ? "写追记 (\(replyCount))" : "添加追记")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundColor(hasReplies ? FlomoPalette.accent(scheme) : FlomoPalette.textSecondary(scheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                            .background(
                                Capsule().fill(hasReplies ? FlomoPalette.accentSoft(scheme) : FlomoPalette.canvas(scheme))
                            )
                            .overlay(
                                Capsule().stroke(hasReplies ? FlomoPalette.accent(scheme).opacity(0.32) : FlomoPalette.border(scheme), lineWidth: 0.8)
                            )
                            .whimClickable(cornerRadius: 12, hoverFill: !hasReplies)
                        }
                        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlomoPalette.card(scheme))
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.35 : 0.08), radius: 14, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlomoPalette.border(scheme), lineWidth: 0.8)
        )
        .onAppear { loadRepliesIfNeeded() }
        .onChange(of: isTop) { _, top in if top { loadRepliesIfNeeded() } }
        .onChange(of: vm.repliesVersion) { _, _ in loadRepliesIfNeeded() }
        .onChange(of: note.replyCount) { _, _ in loadRepliesIfNeeded() }
    }
}

private struct FlomoCardDeckView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var vm: WhimStoreVM
    let notes: [WhimNote]
    let isRandomMode: Bool
    let resetKey: String
    @Binding var editingNoteId: String?
    let searchFocused: Bool
    let onTapTag: (String) -> Void
    let onTapImages: ([String], Int) -> Void
    let onOpenThread: (WhimNote) -> Void
    let onReshuffle: () -> Void

    @State private var currentIndex: Int = 0
    @State private var dragOffset: CGSize = .zero
    @State private var isAnimatingOut: Bool = false

    private var shortcutsEnabled: Bool {
        editingNoteId == nil && !searchFocused
    }

    var body: some View {
        VStack(spacing: 16) {
            if notes.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: isRandomMode ? "shuffle" : "sparkles")
                        .font(.system(size: 28))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                    Text(isRandomMode ? "暂无可随机漫步的历史笔记" : "这一天还没有记录笔记")
                        .font(.system(size: 14))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                }
                Spacer()
            } else if currentIndex >= notes.count {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(FlomoPalette.accent(scheme))
                    Text(isRandomMode ? "本批 \(notes.count) 条灵感已漫步完毕" : "今日 \(notes.count) 条记录已全部回顾")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundColor(FlomoPalette.textPrimary(scheme))
                    HStack(spacing: 12) {
                        if currentIndex > 0 {
                            WhimSecondaryButton(title: "回看上一张", compact: true) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    currentIndex = max(0, notes.count - 1)
                                }
                            }
                        }
                        WhimPrimaryButton(title: isRandomMode ? "换一批" : "重新回顾", compact: true) {
                            if isRandomMode {
                                currentIndex = 0
                                onReshuffle()
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                    currentIndex = 0
                                }
                            }
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: 420)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FlomoPalette.card(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(FlomoPalette.border(scheme), lineWidth: 0.8))
                Spacer()
            } else {
                let visibleEnd = min(notes.count, currentIndex + 3)
                let visibleIndices = Array((currentIndex..<visibleEnd).reversed())
                let dragProgress = min(abs(dragOffset.width) / 140.0, 1.0)

                ZStack {
                    ForEach(visibleIndices, id: \.self) { idx in
                        let depth = idx - currentIndex
                        let note = notes[idx]
                        let isTop = depth == 0
                        let scale: CGFloat = isTop ? 1.0 : (1.0 - CGFloat(depth) * 0.045 + CGFloat(dragProgress) * 0.045)
                        let yOffset: CGFloat = isTop ? 0 : (CGFloat(depth) * 16.0 - CGFloat(dragProgress) * 16.0)
                        let opacity: Double = isTop ? 1.0 : max(0.45, 1.0 - Double(depth) * 0.22 + dragProgress * 0.22)

                        DeckCardItemView(
                            vm: vm,
                            note: note,
                            isTop: isTop,
                            editingNoteId: $editingNoteId,
                            onTapTag: onTapTag,
                            onTapImages: onTapImages,
                            onOpenThread: onOpenThread
                        )
                        .id(note.id)
                        .scaleEffect(scale)
                        .offset(x: isTop ? dragOffset.width : 0, y: yOffset)
                        .rotationEffect(.degrees(isTop ? Double(dragOffset.width / 28.0) : 0))
                        .opacity(opacity)
                        .zIndex(Double(notes.count - idx))
                        .allowsHitTesting(isTop)
                        .gesture(
                            isTop && editingNoteId != note.id ?
                            DragGesture(minimumDistance: 16)
                                .onChanged { val in
                                    if abs(val.translation.width) > abs(val.translation.height) * 1.1 {
                                        dragOffset = CGSize(width: val.translation.width, height: 0)
                                    }
                                }
                                .onEnded { val in
                                    if abs(val.translation.width) > 95 && abs(val.translation.width) > abs(val.translation.height) {
                                        swipeOut(direction: val.translation.width >= 0 ? 1 : -1)
                                    } else {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                            dragOffset = .zero
                                        }
                                    }
                                }
                            : nil
                        )
                    }
                }
                .frame(maxWidth: 660, maxHeight: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 22)

                HStack(spacing: 14) {
                    WhimSecondaryButton(title: "上一张", icon: "chevron.left", compact: true) {
                        goPrev()
                    }
                    .disabled(currentIndex == 0)

                    Text("\(currentIndex + 1) / \(notes.count)")
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                        .frame(minWidth: 56)

                    WhimPrimaryButton(title: currentIndex + 1 >= notes.count ? "完成" : "下一张", icon: "chevron.right", compact: true) {
                        swipeOut(direction: -1)
                    }

                    Text("左右拖拽或按 ← / → / 空格切卡")
                        .font(.system(size: 11))
                        .foregroundColor(FlomoPalette.textMuted(scheme))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: resetKey) { _, _ in
            currentIndex = 0
            dragOffset = .zero
        }
        .background(
            Group {
                if shortcutsEnabled && !notes.isEmpty {
                    Button("") { goPrev() }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                    Button("") { if currentIndex < notes.count { swipeOut(direction: -1) } }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                    Button("") { if currentIndex < notes.count { swipeOut(direction: -1) } }
                        .keyboardShortcut(.space, modifiers: [])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                }
            }
        )
    }

    private func goPrev() {
        guard currentIndex > 0, !isAnimatingOut else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            currentIndex -= 1
            dragOffset = .zero
        }
    }

    private func swipeOut(direction: CGFloat) {
        guard !isAnimatingOut, currentIndex < notes.count else { return }
        isAnimatingOut = true
        withAnimation(.easeOut(duration: 0.2)) {
            dragOffset = CGSize(width: direction * 560, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.19) {
            currentIndex += 1
            dragOffset = .zero
            isAnimatingOut = false
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
                        .frame(width: 28, height: 28)
                        .whimClickable(cornerRadius: 7, hoverFill: true)
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
                .help(isPinned ? "已固定在屏幕最前（发送后不关闭）" : "固定在屏幕最前")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                        .frame(width: 28, height: 28)
                        .whimClickable(cornerRadius: 7, hoverFill: true)
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
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
                                    .padding(.vertical, 3.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(active ? FlomoPalette.accent(scheme) : FlomoPalette.tagBg(scheme))
                                    )
                                    .whimClickable(cornerRadius: 5, hoverFill: false)
                            }
                            .buttonStyle(WhimTactileButtonStyle(cornerRadius: 5))
                        }
                    }
                }
            }

            HStack(spacing: 8) {
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
                        .whimClickable(cornerRadius: 7, hoverFill: false)
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 7))
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
                .frame(width: 28, height: 26)
                .whimClickable(cornerRadius: 6, hoverFill: true)
        }
        .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
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
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let vm = WhimStoreVM()
    var statusItem: NSStatusItem?
    var statusPopover: NSPopover?
    var quickPanel: QuickCapturePanel?
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        setupMainMenu()
        vm.boot()
        setupMenuBar()
        setupMainWindow()
        GlobalHotKeyManager.shared.registerCmdShiftJ { [weak self] in
            self?.toggleQuickCapture()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard let self else { return }
            if actionId == WhimStoreVM.reviewActionSnooze {
                self.vm.scheduleSnoozeReviewNotification(minutes: 30)
            } else {
                self.vm.openDailyReviewToday()
                self.showMainWindow()
            }
        }
        completionHandler()
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

    private func makeMenuBarSquirrelIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 19, height: 19)
            img.isTemplate = true
            return img
        }
        return NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Whim")
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            btn.image = makeMenuBarSquirrelIcon()
            btn.imagePosition = .imageOnly
            btn.toolTip = "Whim"
            btn.target = self
            btn.action = #selector(toggleStatusPopover(_:))
        }
        statusItem = item
    }

    private func closeStatusPopover() {
        statusPopover?.performClose(nil)
    }

    @objc func toggleStatusPopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if let popover = statusPopover, popover.isShown {
            popover.performClose(sender)
            return
        }
        vm.refreshTopPinnedNote()
        let popover = statusPopover ?? {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            statusPopover = p
            return p
        }()
        let savedTheme = AppThemeMode(rawValue: UserDefaults.standard.string(forKey: "whim.themeMode") ?? "system") ?? .system
        let rootView = StatusBarPopoverView(
            vm: vm,
            onNewNote: { [weak self] in
                self?.closeStatusPopover()
                self?.toggleQuickCapture()
            },
            onOpenMainWindow: { [weak self] in
                self?.closeStatusPopover()
                self?.showMainWindow()
            },
            onSelectTag: { [weak self] path in
                guard let self else { return }
                self.closeStatusPopover()
                self.vm.activeTab = .tag(path)
                self.vm.applyFilter()
                self.showMainWindow()
            },
            onSyncNow: { [weak self] in
                self?.vm.syncNow()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
        .preferredColorScheme(savedTheme.colorScheme)
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc func showMainWindow() {
        if mainWindow == nil {
            setupMainWindow()
        }
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let win = mainWindow {
            if win.isMiniaturized {
                win.deminiaturize(nil)
            }
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        }
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
