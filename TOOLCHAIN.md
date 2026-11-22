# Whim — 本机工具链与构建环境记录 (TOOLCHAIN.md)

本文档记录当前 Mac 开发机识别到的工具链路径、版本、实测避坑项与直接可用的构建命令，方便后续开发和排错直接复用。

## 1. 已识别的本机工具链（2026-11-23）

| 工具 | 路径 | 版本 | 用途与备注 |
| :--- | :--- | :--- | :--- |
| **Go** | `/usr/local/go/bin/go` | `go1.27.3 darwin/arm64` | 构建 `core/`、`cmd/whim-mcp`、C 静态库与 `gomobile` |
| **Swift** | `/usr/bin/swift` / `/usr/bin/swiftc`（CommandLineTools） | `Apple Swift 6.2.4 (arm64-apple-macosx15.0)` | 构建 `macos/` SwiftUI + AppKit 应用（无需完整 Xcode） |
| **Java (JDK)** | `/opt/homebrew/opt/openjdk/bin/java` | `OpenJDK 26.0.1` | Android Gradle CLI 运行时 |
| **Gradle** | `/opt/homebrew/bin/gradle` | Homebrew `gradle@9` | Android CLI 构建 |
| **Xcode** | 仅安装 CommandLineTools | 无完整 `xcodebuild` | macOS 端采用 `go build -buildmode=c-archive` + `swiftc` 直编链接，绕开完整 Xcode 依赖 |

## 2. 实测避坑记录

1. **Go 在受限/沙箱终端下拉取依赖报 `x509: OSStatus -26276`**：
   - 原因：macOS SecTrust 系统钥匙串在沙箱内被拦。
   - 解决：设置 `export SSL_CERT_FILE="/etc/ssl/cert.pem"` 后再运行 `go mod tidy` 或 `go get`。
2. **macOS `swift build` 报 `sandbox-exec: sandbox_apply: Operation not permitted`**：
   - 原因：SwiftPM 解析 `Package.swift` 时会嵌套调用 `sandbox-exec`。
   - 解决：`scripts/build-macos.sh` 已改为直接调用 `swiftc -O -parse-as-library` 链接 `libwhimcore.a`（同时保留 `Package.swift` 供编辑器补全），编译仅需约 2 秒，且无 Xcode 依赖。
3. **Android 端构建前置条件**：
   - 本机需配置 `ANDROID_HOME`（通常为 `~/Library/Android/sdk`）与 NDK，并安装一次 `gomobile`：
     ```bash
     export PATH="/usr/local/go/bin:$(go env GOPATH)/bin:$PATH"
     go install golang.org/x/mobile/cmd/gomobile@latest
     gomobile init
     ```

## 3. 常用构建命令速查

### Go 核心测试
```bash
cd core && /usr/local/go/bin/go test ./... -v
```

### 编译 macOS 本地 MCP Server (`dist/whim-mcp`, ~8.0 MB)
```bash
./scripts/build-mcp.sh
```

### 编译 macOS 共享静态库 + SwiftUI 应用 (`dist/Whim.app`, ~12 MB)
```bash
./scripts/build-macos.sh
open dist/Whim.app
```

### 编译 Android 共享库 (`whimcore.aar`) + Kotlin 2.0 APK（无 Android Studio）
```bash
./scripts/build-android.sh
# 产物: android/app/build/outputs/apk/debug/app-debug.apk
# 安装到真机: adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```
