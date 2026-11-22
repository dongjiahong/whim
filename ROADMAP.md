# Whim — 开发路线图与追踪清单 (ROADMAP.md)

本文档用于长期追踪 Whim 的开发进度。原则：**先跑通 Go 核心与双端绑定构建链，再做同步与 Android 端（攻克后台与通知痛点），接着做 macOS 端与 MCP Server**。

---

## Phase 0：工程脚手架与构建链验证
- [x] 初始化 `core/` Go module，引入 `modernc.org/sqlite` 并验证纯 Go SQLite 编译通过
- [x] 编写 `scripts/build-android.sh`（`gomobile bind -target=android` + Gradle CLI）
- [x] 初始化 `android/`（Kotlin 2.0 + Jetpack Compose + Gradle CLI 工程结构）
- [x] 编写 `scripts/build-core-macos.sh` 与 `scripts/build-macos.sh`（`c-archive` + `swiftc` 产出 `dist/Whim.app`）
- [ ] 在宿主机终端执行 `./scripts/build-android.sh` 验证真机 APK 编译与安装

---

## Phase 1：Go 核心存储、多级标签、图片 Blob 与 Markdown 导出
- [x] 实现 SQLite WAL 初始化与 Schema 迁移（`notes`、`note_tags`、`note_attachments`、`sync_peers`、`notes_fts`）
- [x] 实现笔记 CRUD、字段级时间戳（`stamps_json`）与软删除墓碑逻辑
- [x] 实现多级标签解析器（提取 `#a/b/c`、标签树聚合统计与按前缀筛选）
- [x] 实现图片 Content-Addressed Blob 存储（`SHA-256` 落盘、去重）
- [x] 实现中文友好的关键词检索与按日期查询（服务于「今日复盘」）
- [x] 实现按需 Markdown 导出器（按日 `.md` + `attachments/` 目录）
- [x] 定义并实现 `core/mobile/`（Android）与 `core/cbridge/`（macOS）导出层

---

## Phase 2：无主从 P2P 局域网同步引擎（含图片 Blob）
- [x] 实现 6 位配对码管理、`/sync/challenge` 一次性 nonce 与 `HMAC-SHA256` 鉴权（含 5 次失败锁定 60 秒）
- [x] 实现 UDP 定向广播发现器（按网卡子网广播、源地址回读 IP、忽略自身广播）
- [x] 实现 HTTP 双向增量交换 `/sync/exchange` 与字段级 LWW 合并（含 5 分钟水位容差）
- [x] 实现图片 Blob 增量同步（`/sync/blobs/{sha256}` GET/PUT + SHA-256 校验）
- [x] 双节点回环集成测试全部通过（并发字段合并、墓碑删除传播、图片双向同步、错码锁定）

---

## Phase 3：Android 端（Kotlin 2.0 + Jetpack Compose）
- [x] 落地 `DESIGN.md` 视觉系统：语义色板、自定义分层软阴影 `Modifier` 与 `6px` 内嵌高光圆形按钮（待放入 `InterTight` `.ttf` 字体文件以替换系统回退字体）
- [x] 实现时间线卡片流、多级标签树面板、搜索与置顶/删除
- [x] 实现极速悬浮速记浮层 `QuickCaptureActivity`（`#` 标签联想、剪贴板贴图、相册选图、Share Sheet 接收文字/图片）
- [x] 实现系统级入口：`WhimTileService`（下拉快捷开关）、`WhimWidgetProvider`（桌面小组件）
- [x] 实现 `SyncWorker`（WorkManager Wi-Fi 周期同步 + 写后立即静默同步）与前台对等监听
- [x] 实现 `DailyReviewScheduler` + `DailyReviewReceiver`（AlarmManager 晚间复盘系统通知 + 开机自恢复）与「今日复盘」视图
- [ ] 真机实测：APK 编译安装、杀进程后晚间复盘通知与后台静默同步验收

---

## Phase 4：macOS 端（SwiftUI + AppKit）
- [x] 延续 `DESIGN.md` 视觉风格（无边框分层阴影卡片、柔和内嵌高光圆形按钮）
- [x] 实现菜单栏常驻图标 + 全局快捷键 `⌘⇧J` 呼出悬浮速记窗（支持 `⌘V` 贴图、`⌘↩` 保存隐藏）
- [x] 实现主窗口时间线、多级标签侧边栏、搜索、今日复盘与一键导出 Markdown
- [x] 接入 Go 对等同步监听（`:8788` HTTP + `:8789` UDP）与 `UNUserNotificationCenter` 晚间复盘提醒
- [x] 编译打包产出 `dist/Whim.app`（~12 MB）
- [ ] 实机验收：与 Android 真机同 Wi-Fi 配对码双向同步 + 图片互传

---

## Phase 5：本地 MCP Server 与长期打磨
- [x] 实现并编译 `dist/whim-mcp`（stdio MCP 协议，~8.0 MB），直接读写本地 `whim.sqlite3`（WAL 模式）
- [x] 通过 JSON-RPC stdio 联调验证 6 个工具：`whim_list_notes`、`whim_search_notes`、`whim_list_tags`、`whim_create_note`、`whim_update_tags`、`whim_export_markdown`
- [ ] 在 Claude Desktop / Cursor / Gemini CLI 中配置并实测「每晚/每周碎片整理」工作流
- [ ] 补齐每日本地自动备份（保留最近 7 天）与 Inter Tight 字体文件打包
