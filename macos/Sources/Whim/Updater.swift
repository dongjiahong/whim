import AppKit
import Foundation
import SwiftUI

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
            case size
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
        case htmlUrl = "html_url"
    }
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onFinish: (URL?, Error?) -> Void
    private var completed = false

    init(onProgress: @escaping (Double) -> Void, onFinish: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let ratio = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        onProgress(ratio)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move to a stable temp file immediately before URLSession deletes `location` upon return.
        let fm = FileManager.default
        let stableTemp = fm.temporaryDirectory.appendingPathComponent("whim-dl-\(UUID().uuidString).zip")
        do {
            try fm.moveItem(at: location, to: stableTemp)
            completed = true
            onFinish(stableTemp, nil)
        } catch {
            completed = true
            onFinish(nil, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !completed {
            completed = true
            onFinish(nil, error)
        }
        session.finishTasksAndInvalidate()
    }
}

@MainActor
final class GitHubUpdater: ObservableObject {
    static let shared = GitHubUpdater()
    static let repo = "dongjiahong/whim"
    static let currentVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }()

    private static let lastAutoCheckKey = "whim.update.lastAutoCheckAt"
    private static let skippedTagKey = "whim.update.skippedTag"
    private static let autoCheckCooldownSec: TimeInterval = 6 * 3600

    @Published var status: String = "点击检查 GitHub 最新版本"
    @Published var checking: Bool = false
    @Published var downloading: Bool = false
    @Published var downloadProgress: Double = 0
    @Published var latestRelease: GitHubRelease? = nil
    @Published var hasUpdate: Bool = false

    private var didScheduleLaunchCheck = false

    func silentCheckOnLaunch() {
        guard !didScheduleLaunchCheck else { return }
        didScheduleLaunchCheck = true
        let last = UserDefaults.standard.double(forKey: Self.lastAutoCheckKey)
        if last > 0 && Date().timeIntervalSince1970 - last < Self.autoCheckCooldownSec {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkForUpdates(silent: true)
        }
    }

    func skipCurrentRelease() {
        if let tag = latestRelease?.tagName {
            UserDefaults.standard.set(tag, forKey: Self.skippedTagKey)
        }
        hasUpdate = false
        status = "已跳过此版本提醒，可随时手动检查更新"
    }

    func checkForUpdates(silent: Bool = false) {
        guard !checking else { return }
        checking = true
        if !silent {
            status = "正在检查 GitHub Release..."
        }
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Whim/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                self.checking = false
                if silent {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastAutoCheckKey)
                }
                if let err {
                    if !silent {
                        self.status = "检查失败：\(err.localizedDescription)"
                    }
                    return
                }
                if let http = resp as? HTTPURLResponse {
                    if http.statusCode == 404 {
                        if !silent {
                            self.status = "当前已是最新版本（仓库暂未发布 Release）"
                        }
                        self.hasUpdate = false
                        return
                    }
                    if !(200...299).contains(http.statusCode) {
                        if !silent {
                            self.status = "检查失败：HTTP \(http.statusCode)"
                        }
                        return
                    }
                }
                guard let data, let rel = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    if !silent {
                        self.status = "解析 Release 信息失败"
                    }
                    return
                }
                self.latestRelease = rel
                let remoteVer = rel.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                if Self.isNewer(remote: remoteVer, current: Self.currentVersion) {
                    let skipped = UserDefaults.standard.string(forKey: Self.skippedTagKey)
                    if silent && skipped == rel.tagName {
                        self.hasUpdate = false
                        return
                    }
                    if !silent {
                        UserDefaults.standard.removeObject(forKey: Self.skippedTagKey)
                    }
                    self.hasUpdate = true
                    self.status = "发现新版本 \(rel.tagName)"
                } else {
                    self.hasUpdate = false
                    if !silent {
                        self.status = "当前已是最新版本 (v\(Self.currentVersion))"
                    }
                }
            }
        }.resume()
    }

    func downloadAndInstall() {
        guard let rel = latestRelease, !downloading else { return }
        guard let asset = rel.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("macos") })
                ?? rel.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) else {
            if let url = URL(string: rel.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let downloadURL = URL(string: asset.browserDownloadUrl) else { return }
        downloading = true
        downloadProgress = 0
        status = "正在下载 \(asset.name)..."

        let delegate = UpdateDownloadDelegate(
            onProgress: { [weak self] ratio in
                DispatchQueue.main.async {
                    self?.downloadProgress = ratio
                    self?.status = "正在下载 \(asset.name)（\(Int(ratio * 100))%）..."
                }
            },
            onFinish: { [weak self] tempURL, err in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.downloading = false
                    if let err {
                        self.status = "下载失败：\(err.localizedDescription)"
                        return
                    }
                    guard let tempURL else {
                        self.status = "下载失败：临时文件丢失"
                        return
                    }
                    self.extractAndReplace(zipURL: tempURL, assetName: asset.name)
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: downloadURL).resume()
    }

    private func extractAndReplace(zipURL: URL, assetName: String) {
        do {
            let fm = FileManager.default
            let workDir = fm.temporaryDirectory.appendingPathComponent("whim-update-\(UUID().uuidString)")
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipPath = workDir.appendingPathComponent(assetName)
            try fm.moveItem(at: zipURL, to: zipPath)

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-xk", zipPath.path, workDir.path]
            try unzip.run()
            unzip.waitUntilExit()

            let newApp = workDir.appendingPathComponent("Whim.app")
            guard fm.fileExists(atPath: newApp.path) else {
                self.status = "解压完成，请在打开的文件夹中手动替换 Whim.app"
                NSWorkspace.shared.open(workDir)
                return
            }

            // Strip macOS Gatekeeper quarantine attribute so ad-hoc/unsigned personal builds launch cleanly.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", newApp.path]
            try? xattr.run()
            xattr.waitUntilExit()

            let currentApp = Bundle.main.bundleURL
            if currentApp.pathExtension == "app" {
                let backupApp = currentApp.deletingLastPathComponent().appendingPathComponent(".Whim.app.bak")
                let script = """
                sleep 1
                rm -rf "\(backupApp.path)"
                if mv "\(currentApp.path)" "\(backupApp.path)"; then
                  if mv "\(newApp.path)" "\(currentApp.path)"; then
                    rm -rf "\(backupApp.path)"
                    xattr -dr com.apple.quarantine "\(currentApp.path)" 2>/dev/null || true
                    open "\(currentApp.path)"
                  else
                    mv "\(backupApp.path)" "\(currentApp.path)"
                    open "\(currentApp.path)"
                  fi
                fi
                """
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                proc.arguments = ["-c", script]
                try proc.run()
                NSApp.terminate(nil)
            } else {
                self.status = "新版本已下载，正在打开目录"
                NSWorkspace.shared.open(workDir)
            }
        } catch {
            self.status = "安装失败：\(error.localizedDescription)"
        }
    }

    static func isNewer(remote: String, current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }
}

struct AboutUpdateView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var updater = GitHubUpdater.shared
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Whim")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(FlomoPalette.textPrimary(scheme))
                    Text("当前版本：v\(GitHubUpdater.currentVersion) · 本地优先闪念笔记")
                        .font(.system(size: 12.5))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(FlomoPalette.textSecondary(scheme))
                        .frame(width: 26, height: 26)
                        .whimClickable(cornerRadius: 6, hoverFill: true)
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("GitHub Release 在线更新")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FlomoPalette.textPrimary(scheme))
                Text(updater.status)
                    .font(.system(size: 12))
                    .foregroundColor(FlomoPalette.textSecondary(scheme))

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
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(FlomoPalette.canvas(scheme)))
                }
            }

            HStack(spacing: 10) {
                WhimSecondaryButton(title: updater.checking ? "检查中..." : "检查更新", compact: true) {
                    updater.checkForUpdates()
                }
                .disabled(updater.checking || updater.downloading)

                if updater.hasUpdate {
                    WhimPrimaryButton(title: updater.downloading ? "下载安装中..." : "一键更新并重启", compact: true) {
                        updater.downloadAndInstall()
                    }
                    .disabled(updater.downloading)
                }

                Spacer()

                Button {
                    if let url = URL(string: "https://github.com/\(GitHubUpdater.repo)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("打开 GitHub")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(FlomoPalette.tagText(scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .whimClickable(cornerRadius: 6, hoverFill: true)
                }
                .buttonStyle(WhimTactileButtonStyle(cornerRadius: 6))
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(FlomoPalette.card(scheme))
        .preferredColorScheme(.dark)
    }
}
