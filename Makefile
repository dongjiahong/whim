.PHONY: help version test macos install-macos android install-android mcp release

help:
	@echo "Whim 常用命令："
	@echo "  make version           查看当前版本号与最近 Git Tag"
	@echo "  make test              运行 Go 核心单元测试与双向同步集成测试"
	@echo "  make macos             编译打包 macOS dist/Whim.app"
	@echo "  make install-macos     编译并安装到 /Applications/Whim.app 且立即启动"
	@echo "  make mcp               编译本地 MCP Server (dist/whim-mcp)"
	@echo "  make android           编译 whimcore.aar 与 Android Release APK"
	@echo "  make install-android   编译并 adb 覆盖安装到已连接 Android 手机"
	@echo "  make release v=0.1.1   同步双端版本号、跑测试、打 tag 并推送触发 GitHub Release"

version:
	@ver=$$(tr -d '[:space:]' < VERSION); \
	tag=$$(git describe --tags --abbrev=0 2>/dev/null || echo "无"); \
	echo "当前版本 (VERSION): $$ver"; \
	echo "最近 Tag (git):     $$tag"

test:
	./scripts/test.sh

macos:
	./scripts/build-macos.sh

install-macos:
	./scripts/install-macos.sh

mcp:
	./scripts/build-mcp.sh

android:
	./scripts/build-android.sh

install-android:
	./scripts/install-android.sh

release:
	@if [ -z "$(v)" ]; then echo "用法: make release v=0.1.1"; exit 1; fi
	./scripts/release.sh "$(v)"
