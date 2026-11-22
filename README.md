# Whim

一款**本地优先（Local-First）**、**macOS 与 Android 原生双端互通**的闪念卡片笔记应用。  
受 [flomo](https://help.flomoapp.com/) 的极简记录心智启发，去掉云端账号锁定，补齐**桌面与移动端极致速记入口**、**光标处图文混排贴图**、**无主从局域网后台双向同步**、**Android 系统级晚间复盘通知**以及**本地 MCP Server**。

---

## 核心特性

- **双端统一 flomo 极简风格**：深炭灰画布 + 森绿主色 + 冷蓝多级标签胶囊；侧栏内置 `笔记 / 标签 / 天` 三列统计与可点击按日筛选的 **12 周活跃热力图**。
- **光标处内联贴图（图文混排）**：不同于把图片统一堆在底部的做法，在 Whim 中直接 `⌘V` 粘贴图片会将图片精准插在当前正文光标位置（`![image](whim://blob/<sha256>)`），多张图片各就各位；导出 Markdown 时同样原样保留图文顺序。
- **极致速记入口**：
  - **macOS**：菜单栏常驻 + 全局快捷键 `⌘⇧J` 呼出可拖动、可 **Pin 固定在屏幕最前**的「新建」悬浮窗（Pin 状态下发送不关闭，方便连续记录）；主窗口顶部自带内联编辑器。
  - **Android**：支持**下拉快捷开关（Quick Settings Tile）**、**桌面小组件（Widget）**与**系统分享菜单（Share Sheet）**直达悬浮速记。
- **无主从（Peer-to-Peer）局域网双向同步**：
  - 同一份 Go 核心库编译进 macOS（`c-archive`）与 Android（`gomobile` `.aar`）。
  - 按网卡定向 UDP 广播自动发现对端 + **6 位配对码 HMAC-SHA256 挑战鉴权**（5 次错码锁定 60 秒）+ 字段级时间戳/墓碑合并 + **SHA-256 图片去重 Blob 增量互传**。
  - Android 后台由系统 **`WorkManager`** 驱动（写后即推 + Wi-Fi 周期保底），彻底解决「必须保持前台才能同步」的痛点。
- **每日回顾、随机漫步与系统通知**：
  - **每日回顾**：支持按日翻页回顾过往任意一天的记录；Android 端使用 `AlarmManager` 定时弹出晚间复盘系统通知（杀进程/重启后依然准时触发），点击直达当日复盘。
  - **随机漫步**：一键「换一批」随机重温历史闪念。
- **本地 SQLite + Markdown 导出 + MCP Server**：
  - 纯 Go `modernc.org/sqlite`（WAL 模式）作为唯一主库，支持一键导出按日分组的 Markdown 与图片附件。
  - 内置独立本地 MCP Server（`whim-mcp`，stdio 协议），直接接入 Claude / Cursor / Gemini CLI 定期整理碎片想法、打标签与归档。
- **GitHub Release 一键检查更新**：双端均内置「关于与更新」页面，可直接检查 GitHub Release 并一键下载更新（覆盖安装，保留全部本地数据）。

---

## 技术架构

```text
whim/
├── core/                      # Go 共享核心（pure Go SQLite WAL / 标签树 / Blob / P2P 同步 / Markdown 导出）
│   ├── mobile/                # Android gomobile bind 导出层 -> whimcore.aar
│   ├── cbridge/               # macOS C-ABI 静态库桥接层 -> libwhimcore.a
│   └── cmd/whim-mcp/          # macOS 本地 stdio MCP Server
├── macos/                     # SwiftUI + AppKit 原生应用（含 NSTextView 内联图文编辑器）
├── android/                   # Kotlin 2.0 + Jetpack Compose（CLI Gradle，无需 Android Studio）
├── scripts/                   # 一键构建脚本
└── .github/workflows/         # 推 v* tag 自动发布 macOS / Android / MCP Release
```

更多细节请查阅：[PRODUCT.md](PRODUCT.md) · [ARCHITECTURE.md](ARCHITECTURE.md) · [DESIGN.md](DESIGN.md) · [ROADMAP.md](ROADMAP.md) · [TOOLCHAIN.md](TOOLCHAIN.md)

---

## 快速构建与运行

### 1. 运行 Go 核心测试
```bash
cd core && go test ./... -v
```

### 2. 编译并运行 macOS 应用（无需完整 Xcode，CommandLineTools 即可）
```bash
./scripts/build-macos.sh
open dist/Whim.app
```

### 3. 编译本地 MCP Server
```bash
./scripts/build-mcp.sh
# 产物：dist/whim-mcp
```
在 Claude Desktop / Cursor / Gemini CLI 中配置 stdio MCP：
```json
{
  "mcpServers": {
    "whim": {
      "command": "/path/to/whim/dist/whim-mcp"
    }
  }
}
```

### 4. 编译 Android APK（Kotlin 2.0 + Jetpack Compose，无需 Android Studio）
```bash
# 首次安装 gomobile：
go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init

./scripts/build-android.sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

### 5. 发布新版本（触发双端一键更新）
```bash
git tag v0.1.0 && git push origin v0.1.0
```
GitHub Actions 会自动编译并发布 `Whim-macOS.zip`、`whim-mcp-macos-arm64.tar.gz` 与 `Whim-Android.apk` 到 GitHub Releases，双端在「关于与更新」里即可直接检查并一键升级。

## License

MIT
