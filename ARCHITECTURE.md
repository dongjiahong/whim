# Whim — 技术架构设计 (ARCHITECTURE.md)

## 1. 总体架构：Go 共享核心 + 双端原生 UI

Whim 采用 **「单一 Go 核心库 + 双端原生界面 + 独立 MCP CLI」** 架构，所有业务规则、数据库读写、标签解析、同步协议和图片去重只写一份 Go 代码，彻底消除跨端逻辑漂移。

```text
┌───────────────────────────────────────────────────────────────────┐
│                         whim Monorepo                             │
├─────────────────────────┬───────────────────────┬─────────────────┤
│   macOS App (SwiftUI)   │ Android App (Kotlin)  │ whim-mcp (CLI)  │
│  - 菜单栏 + 全局快捷键   │ - Jetpack Compose UI  │ - stdio MCP     │
│  - 悬浮速记窗 + 贴图     │ - Quick Settings Tile │ - 直接读本机 DB │
│  - UNUserNotification   │ - Widget / ShareSheet │   供 AI 整理    │
│                         │ - WorkManager 后台同步│                 │
│                         │ - AlarmManager 复盘提醒│                │
├─────────────────────────┴───────────────────────┴─────────────────┤
│                Go Shared Core (core/ + mobile/)                   │
│   编译为：WhimCore.xcframework (macOS) / whimcore.aar (Android)   │
│  - SQLite (modernc.org/sqlite, pure Go, WAL 模式)                 │
│  - 多级标签解析与全文检索 (FTS5)                                   │
│  - Content-Addressed Blob 存储 (SHA-256 图片去重)                 │
│  - 对等同步引擎 (UDP 发现 + HTTP 双向增量 + HMAC 配对码 + Blob同步) │
│  - Markdown 按需导出器                                             │
└───────────────────────────────────────────────────────────────────┘
```

### 关键释疑：为什么 Go 不是“在手机上跑一个独立后台服务”？

- **进程内库嵌入（In-Process Library）**：通过 `gomobile bind`，Go 核心被直接编译成 Android 的 `.aar`（内含 `arm64-v8a` 等 `.so` 和自动生成的 Kotlin/Java 绑定类）和 macOS 的 `.xcframework`。
- **没有独立常驻守护进程**：Android 的 Kotlin UI 和 `WorkManager` 后台任务像调用普通 Kotlin 函数一样直接调用 `WhimCore.createNote(...)`、`WhimCore.syncOnce()`。
- **纯 Go SQLite 避坑**：使用 `modernc.org/sqlite`（纯 Go，无 CGO 依赖），避免 `gomobile` 打包时因 `mattn/go-sqlite3` 的 NDK/CGO 交叉编译产生脆弱问题。

---

## 2. 无主从（Peer-to-Peer）局域网双向同步设计

### 2.1 对等角色模型
每一端运行完全相同的 Go 同步引擎，**数据层面没有任何主从之分**：
- **对称双向交换**：一次 HTTP `POST /sync/exchange` 请求同时携带「发起方的增量变更 + 已听过的对端水位」，对端合并后在响应里返回「对端的增量变更」。一次往返，两端收敛。
- **为什么两端网络行为有差异（系统约束决定，而非主从）**：
  - **macOS**：电源与后台不受限，App 运行期间在进程内常驻启动 UDP 发现监听（如 `8789`）与 HTTP 同步端口（如 `8788`），同时周期性主动探测其他对端。
  - **Android（前台）**：打开 App 时同样可以开启监听（支持双手机互传或 Mac 主动同步），并在回到前台时立即触发一次 `SyncOnce()`。
  - **Android（后台）**：Android Doze 机制会杀掉长期常驻监听的 Socket。因此后台由原生 `WorkManager` 驱动：
    1. **写后即推**：通过 Widget / Tile / Share Sheet 保存笔记后，立刻提交一个带 `NetworkType.UNMETERED`（仅 Wi-Fi）约束的 `OneTimeWorkRequest`，在后台静默调用 `WhimCore.syncOnce()`。
    2. **周期保底**：注册 `PeriodicWorkRequest`（如每 15–30 分钟、仅 Wi-Fi 条件下）静默执行 `WhimCore.syncOnce()`，确保在 Mac 上写的笔记自动落到手机，晚上复盘前数据永远是最新的。

### 2.2 设备发现与安全配对（沿用 Navigator 验证方案）
1. **UDP 定向广播发现**：
   - 遍历本机活跃非回环网卡，用 IP + 子网掩码算出定向广播地址（如 `192.168.1.255`），避免 `255.255.255.255` 在手机开启蜂窝数据时走错路由。
   - 发送 `WHIM/1 DISCOVER <device_id>`，监听端单播回复 `WHIM/1 OFFER <device_id> <http_port>`。
   - 发起方直接读取 UDP 包的源 IP（`from.IP`），彻底无视 DHCP IP 变更。
2. **6 位配对码鉴权**：
   - 配对码属于笔记库，不直接上公网或明文传输。
   - 同步前先 `GET /sync/challenge` 获取 16 字节一次性 `nonce`（30 秒过期），客户端计算 `HMAC-SHA256(pair_code, nonce)` 放入 `X-Whim-Proof` 请求头。
   - 常量时间比对，连续 5 次失败锁定 60 秒（返回 `429`）。

### 2.3 字段级合并与墓碑（LWW per Field）
每张笔记维护字段级时间戳 `field_stamps`（`content`、`pinned`、`archived`、`deleted`、`attachments`），以及 `updated_at = max(field_stamps)`：
- 并发编辑同一条笔记的不同字段（如 Mac 改正文、手机点归档），合并后两边改动同时保留。
- 同毫秒冲突按字典序（deterministic tie-breaker）裁决，保证任意同步顺序下最终结果一致。
- 删除一律写墓碑（`deleted = 1` + 新时间戳），防止被离线设备复活；撤回删除只需写 `deleted = 0` + 更高时间戳。
- 按对端 `peer_id` 分别记录同步水位（`last_heard_at`），查询增量时自动回退 5 分钟时钟容差窗口（`MARGIN = 5m`）。

### 2.4 图片附件同步（Content-Addressed Blobs）
图片不内联塞进同步 JSON，避免大包拖慢增量同步：
1. 本地粘贴/选图时计算图片字节的 `SHA-256`，保存至 `<dataDir>/blobs/<sha256>.<ext>`（自动去重）。
2. `notes` 同步只传输附件引用列表（`sha256`、`mime`、`size`、`width`、`height`）。
3. 元数据合并完成后，Go 同步引擎检查本地缺失的 `sha256` 列表，调用 `GET /sync/blobs/{sha256}` 拉取缺失图片，并把对端缺失的图片通过 `PUT /sync/blobs/{sha256}` 推过去（带 SHA-256 校验，断点可重试）。

---

## 3. SQLite 数据模型（WAL 模式）

数据库路径：`<dataDir>/whim.sqlite3`，开启 `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;` 以支持 macOS App 与 MCP Server 并发安全读写。

```sql
-- 核心闪念表
CREATE TABLE notes (
    id           TEXT PRIMARY KEY,          -- ULID（天然按时间有序）
    content      TEXT NOT NULL DEFAULT '',
    pinned       INTEGER NOT NULL DEFAULT 0,
    archived     INTEGER NOT NULL DEFAULT 0,
    deleted      INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL,          -- Unix 毫秒
    updated_at   INTEGER NOT NULL,          -- 各字段戳最大值
    stamps_json  TEXT NOT NULL              -- {"content":..., "pinned":..., ...}
);

-- 笔记-多级标签索引表（由 content 中的 #a/b/c 自动解析维护，便于树查询）
CREATE TABLE note_tags (
    note_id      TEXT NOT NULL,
    tag_path     TEXT NOT NULL,             -- 例如 "工作/架构/同步"
    PRIMARY KEY (note_id, tag_path)
);
CREATE INDEX idx_note_tags_path ON note_tags(tag_path);

-- 附件引用表
CREATE TABLE note_attachments (
    id           TEXT PRIMARY KEY,
    note_id      TEXT NOT NULL,
    sha256       TEXT NOT NULL,
    mime         TEXT NOT NULL,
    width        INTEGER NOT NULL DEFAULT 0,
    height       INTEGER NOT NULL DEFAULT 0,
    size_bytes   INTEGER NOT NULL DEFAULT 0,
    sort_order   INTEGER NOT NULL DEFAULT 0,
    deleted      INTEGER NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL
);
CREATE INDEX idx_attachments_note ON note_attachments(note_id);
CREATE INDEX idx_attachments_sha  ON note_attachments(sha256);

-- 同步对端水位表（纯本机状态，不参与同步）
CREATE TABLE sync_peers (
    peer_id       TEXT PRIMARY KEY,
    display_name  TEXT NOT NULL DEFAULT '',
    last_addr     TEXT NOT NULL DEFAULT '',
    last_heard_at INTEGER NOT NULL DEFAULT 0,
    last_sync_at  INTEGER NOT NULL DEFAULT 0
);

-- 全文检索虚拟表
CREATE VIRTUAL TABLE notes_fts USING fts5(
    note_id UNINDEXED,
    content,
    tokenize = 'unicode61'
);
```

---

## 4. 平台原生集成要点

### 4.1 Android（Kotlin 2.0 + Jetpack Compose，纯 CLI Gradle 构建）
不依赖 Android Studio，全部通过 `./gradlew assembleDebug` + `adb install -r` 完成构建与真机调试：
- **速记入口**：
  - `QuickCaptureActivity`：透明/底部浮层 Activity，带 `FLAG_SHOW_WHEN_LOCKED` 可选，打开即自动弹出键盘并聚焦输入框。
  - `WhimTileService`（`TileService`）：系统下拉快捷开关，点击直接拉起 `QuickCaptureActivity`。
  - `WhimWidget`（Jetpack Glance）：主屏小组件，点击直达速记或今日复盘。
  - `Intent.ACTION_SEND` / `ACTION_SEND_MULTIPLE`：接收外部 App 分享的文字、链接和图片。
- **晚间复盘系统通知**：
  - 使用 `AlarmManager.setExactAndAllowWhileIdle`（配合 `BOOT_COMPLETED` 重注册），每日定时触发 `DailyReviewReceiver`。
  - `DailyReviewReceiver` 调 `WhimCore.countTodayNotes()` 获取当日条数，通过 `NotificationManager` 发出系统通知（若当日为 0 条可配置跳过或轻提醒），点击通过 Deep Link 直达 `ReviewScreen`。
- **后台同步**：
  - `SyncWorker`（`CoroutineWorker`）调用 `WhimCore.syncOnce()`，配置 `Constraints(requiredNetworkType = NetworkType.UNMETERED)`。

### 4.2 macOS（SwiftUI + AppKit，SwiftPM / Xcode CLI 构建）
- **菜单栏与悬浮速记窗**：`NSStatusItem` 常驻菜单栏 + `NSPanel`（`nonactivatingPanel` + `.floating` 层级），配合全局快捷键（Carbon HotKey / `KeyboardShortcuts`），在全屏应用上也能瞬间弹出，支持 `⌘V` 直接粘贴剪贴板图片。
- **通知**：`UNUserNotificationCenter` 定时触发每日晚间复盘。

### 4.3 本地 MCP Server (`cmd/whim-mcp`)
独立编译的 Go 二进制，默认走 `stdio` 协议，直接读取 macOS 的 `whim.sqlite3`（WAL 模式）：
- `whim_list_notes(date_from, date_to, tag_prefix, include_archived, limit)`：按时间段或标签前缀拉取闪念。
- `whim_search_notes(query, limit)`：全文检索。
- `whim_list_tags()`：返回完整多级标签树及各节点笔记计数。
- `whim_create_note(content)`：允许 AI 把整理后的复盘结论写回 Whim。
- `whim_update_tags(note_id, add_tags, remove_tags)`：批量给碎片笔记补标签/归类。
- `whim_export_markdown(date_from, date_to, tag_prefix, out_dir)`：触发按需 Markdown 导出。

---

## 5. 推荐仓库目录结构

```text
whim/
├── PRODUCT.md
├── ARCHITECTURE.md
├── DESIGN.md
├── ROADMAP.md
├── core/                      # 共享 Go 模块
│   ├── go.mod
│   ├── store/                 # SQLite WAL, schema, FTS5, tags, blobs
│   ├── sync/                  # UDP 发现, HMAC 鉴权, HTTP 双向交换, Blob 同步
│   ├── export/                # Markdown 导出器
│   ├── mobile/                # gomobile 导出层 (纯基本类型 + JSON/bytes 边界)
│   └── cmd/whim-mcp/          # macOS 本地 MCP Server
├── android/                   # Kotlin 2.0 + Jetpack Compose (CLI Gradle)
│   ├── build.gradle.kts
│   ├── app/libs/whimcore.aar  # 由 scripts/build-core.sh 生成
│   └── app/src/main/kotlin/com/whim/
├── macos/                     # SwiftUI + AppKit
│   ├── Package.swift
│   └── Sources/Whim/
└── scripts/
    ├── build-core-android.sh  # gomobile bind -target=android
    ├── build-core-macos.sh    # gomobile bind -target=macos
    └── build-mcp.sh           # go build ./cmd/whim-mcp
```
