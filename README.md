# Whim

> 捕捉一闪而过的念头——**本地优先（Local-First）**、**macOS 与 Android 原生双端互通**、**AI 就绪**的闪念卡片笔记。

受 [flomo](https://help.flomoapp.com/) 极简卡片记录心智启发，Whim 去掉云端账号与订阅锁定，把所有数据牢牢留在你的本地设备里；同时围绕「**零阻力记录 → 轻量整理 → 定期回顾 → 多端无缝同步 → 本地 AI 协作**」完整闭环，打造原生、克制且可靠的双端体验。

---

## 产品核心特色

### 1. 随时随地，零阻力捕捉灵感
- **macOS 全局速记**：菜单栏常驻，任意界面按下 `⌘⇧J` 即刻呼出悬浮新建窗；支持 **Pin 置顶**（发送后窗口不关闭，适合阅读或开会时连续记录），主窗口顶部亦内置内联编辑器。
- **Android 多入口直达**：支持**下拉快捷开关（Quick Settings Tile）**、**桌面小组件（Widget）**与**系统分享菜单（Share Sheet）**直达悬浮速记；编辑内容**自动保存草稿**，误触关闭或切出应用也不会丢失半句想法。

### 2. 光标处内联贴图 & 沉浸看图
- **所见即所得的图文混排**：不同于把图片统一堆在卡片底部的做法，在 Whim 中 `⌘V` 粘贴或插入图片时，图片会精准落在当前光标处（`![image](whim://blob/<sha256>)`），多图穿插正文各就各位；导出 Markdown 时同样原样保留图文顺序。
- **全屏多图灯箱**：点击卡片图片进入全屏灯箱，支持多图左右切换与双指/滚轮缩放，细看截图与手写笔记毫不费力。

### 3. 像对话一样延展思考：卡片、追记与轻整理
- **追记（Note Threads）**：对历史卡片产生新想法时，可直接沿时间线追加「追记」，既保留原始记录的纯粹，又让思考脉络清晰可循。
- **卡片内直接交互**：
  - 直接点击勾选或取消 Markdown 待办（`- [ ]` ↔ `- [x]`），无需反复进入编辑态。
  - 双击（macOS）/ 双击（Android）卡片即刻进入编辑，搜索结果自动高亮命中关键词。
- **层级标签与极速筛选**：
  - 支持 `#父标签/子标签` 多级标签树，右键（macOS）或长按（Android）即可**原子重命名或合并标签**（自动同步更新所有关联笔记）。
  - 内置 `无标签`、`含图片`、`近 7 天`、`近 30 天` 快捷筛选胶囊，配合侧栏 `笔记 / 标签 / 天` 统计与可点击按日过滤的 **12 周活跃热力图**，几秒定位任意记忆。

### 4. 让记录产生复利：每日回顾与随机漫步
- **叠卡回顾体验**：在「每日回顾」中按天翻阅过往记录，或在「随机漫步」中一键换一批重温沉淀已久的闪念。
- **准点可靠的每日提醒（Android）**：内置自研 Compose 滚轮时间选择器，支持配置多组每日提醒；由系统 `AlarmManager` 驱动并内置电池无限制权限检测，即便划掉后台或息屏也能准时推送，点击直达当日回顾。

### 5. 无主从（P2P）局域网极速同步
- **零云端中转**：同一套 Go 核心同时驱动 macOS 与 Android，设备间直接通过局域网点对点同步，数据不经过任何第三方服务器。
- **轻松配对 & 安全鉴权**：支持局域网 UDP 自动发现，以及 **macOS 二维码 / `whim://pair?...` 链接 / 6 位配对码**快速配对；全程使用 HMAC-SHA256 挑战鉴权（5 次错码自动锁定 60 秒）。
- **实时与后台兼顾**：支持 SSE 实时推送毫秒级唤醒与 Android `WorkManager` 后台保底同步；图片基于 SHA-256 去重按需增量互传，支持**多台 Mac 并行配对**与双向解绑。

### 6. 数据完全属于你：本地优先与多重保险
- **单一本地主库**：采用纯 Go `modernc.org/sqlite`（WAL 模式），完全离线可用。
- **最近删除（30 天回收站）**：删除的卡片先进入回收站，支持一键恢复、彻底清除或 30 天自动清理，避免误删遗憾。
- **WAL 安全自动备份**：应用启动时按日自动生成 WAL 安全的 SQLite 快照（默认滚动保留最近 7 天），并支持手动一键备份与存储空间检查。
- **无损开放导出**：一键导出按日分组的 Markdown 文件与完整图片附件，随时迁移无锁定。

### 7. 原生接入 AI 工作流（Local MCP Server）
- 内置独立本地 stdio MCP Server（`whim-mcp`），可直接接入 **Claude Desktop / Cursor / Gemini CLI**，在不把个人笔记上传至第三方云端的前提下，让 AI 协助检索闪念、梳理标签、总结周报与归档整理。

---

## 双端能力一览

双端均采用平台原生技术栈构建，保持统一克制的视觉语言，支持 **浅色 / 深色 / 跟随系统** 主题与内置 **GitHub Release 一键检查更新**。

| 能力维度 | macOS（SwiftUI + AppKit） | Android（Kotlin 2.0 + Jetpack Compose） |
| :--- | :--- | :--- |
| **速记入口** | 菜单栏常驻 + 全局 `⌘⇧J` 可 Pin 悬浮窗 + 主窗内联编辑 | 下拉快捷开关 + 桌面小组件 + 系统分享菜单 + 草稿自动保存 |
| **编辑与交互** | 光标处 `⌘V` 贴图、双击编辑、待办直勾、多图缩放灯箱 | 光标处插图、双击编辑、待办直勾、多图双指缩放灯箱 |
| **整理与检索** | 12 周热力图、快捷筛选胶囊、右键重命名/合并标签、追记侧栏、搜索高亮 | 12 周热力图、快捷筛选胶囊、长按重命名/合并标签、追记抽屉、搜索高亮 |
| **回顾与提醒** | 每日回顾、随机漫步 | 每日回顾、随机漫步、自研滚轮多时段提醒 + 电池优化检测 |
| **同步与配对** | 二维码 / 6 位配对码、UDP 自动发现、SSE 实时推送、多设备独立配对 | 剪贴板配对链接 / 6 位配对码、UDP 自动发现、WorkManager 后台同步 |
| **数据安全** | 30 天回收站、每日自动备份、Markdown 导出、本地 MCP Server | 30 天回收站、每日自动备份、Markdown 导出、存储空间管理 |

---

## 技术架构

一份 Go 共享核心（存储、标签树、追记、Blob、回收站、WAL 备份、P2P 同步、Markdown 导出），同时编译为 macOS 静态库、Android AAR 与本地 MCP Server，确保双端数据模型与同步协议 100% 一致：

```text
whim/
├── core/                      # Go 共享核心（pure Go SQLite WAL / 标签树 / 追记 / Blob / P2P 同步）
│   ├── cbridge/               # macOS C-ABI 静态库桥接层 -> libwhimcore.a
│   ├── mobile/                # Android gomobile bind 导出层 -> whimcore.aar
│   └── cmd/whim-mcp/          # 本地 stdio MCP Server -> dist/whim-mcp
├── macos/                     # SwiftUI + AppKit 原生应用（含 NSTextView 内联图文编辑器）
├── android/                   # Kotlin 2.0 + Jetpack Compose（CLI Gradle，无需 Android Studio）
├── scripts/                   # 跨平台构建、安装与发布脚本
├── Makefile                   # 常用构建与发布快捷入口
└── .github/workflows/         # 推送 v* tag 自动构建并发布双端与 MCP Release
```

更多设计细节请查阅：[产品规格 PRODUCT.md](PRODUCT.md) · [技术架构 ARCHITECTURE.md](ARCHITECTURE.md) · [视觉设计 DESIGN.md](DESIGN.md) · [路线图 ROADMAP.md](ROADMAP.md) · [工具链说明 TOOLCHAIN.md](TOOLCHAIN.md)

---

## 快速构建与运行

项目根目录提供 `Makefile` 统一封装构建与安装命令，macOS 仅需 CommandLineTools（无需完整 Xcode），Android 支持纯 CLI Gradle 构建（无需 Android Studio）。

```bash
# 1. 运行 Go 核心单元测试与双向同步集成测试
make test

# 2. 编译 macOS 应用（产物：dist/Whim.app）或直接安装到 /Applications 并启动
make macos
make install-macos

# 3. 编译 Android whimcore.aar 与 APK，或直接 adb 覆盖安装到已连接设备
# （首次使用需安装 gomobile：go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init）
make android
make install-android

# 4. 编译本地 MCP Server（产物：dist/whim-mcp）
make mcp
```

### 配置本地 MCP Server

在 Claude Desktop、Cursor 或 Gemini CLI 的 MCP 配置中加入：

```json
{
  "mcpServers": {
    "whim": {
      "command": "/path/to/whim/dist/whim-mcp"
    }
  }
}
```

### 发布新版本

```bash
# 同步双端版本号、跑全量测试、打 tag 并推送触发 GitHub Actions 自动发布
make release v=0.2.1
```

GitHub Actions 会自动构建并发布 `Whim-macOS.zip`、`whim-mcp-macos-arm64.tar.gz` 与 `Whim-Android.apk` 到 GitHub Releases，双端在「关于与更新」页面即可一键检查并覆盖升级（保留全部本地数据）。

## License

MIT
