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

@MainActor
final class GitHubUpdater: ObservableObject {
    static let repo = "dongjiahong/whim"
    static let currentVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }()

    @Published var status: String = "点击检查 GitHub 最新版本"
    @Published var checking: Bool = false
    @Published var downloading: Bool = false
    @Published var latestRelease: GitHubRelease? = nil
    @Published var hasUpdate: Bool = false

    func checkForUpdates() {
        guard !checking else { return }
        checking = true
        status = "正在检查 GitHub Release..."
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Whim/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                self.checking = false
                if let err {
                    self.status = "检查失败：\(err.localizedDescription)"
                    return
                }
                if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                    self.status = "当前已是最新版本（仓库暂未发布 Release）"
                    self.hasUpdate = false
                    return
                }
                guard let data, let rel = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    self.status = "解析 Release 信息失败"
                    return
                }
                self.latestRelease = rel
                let remoteVer = rel.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                if Self.isNewer(remote: remoteVer, current: Self.currentVersion) {
                    self.hasUpdate = true
                    self.status = "发现新版本 \(rel.tagName)"
                } else {
                    self.hasUpdate = false
                    self.status = "当前已是最新版本 (v\(Self.currentVersion))"
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
        status = "正在下载 \(asset.name)..."

        URLSession.shared.downloadTask(with: downloadURL) { tempURL, _, err in
            DispatchQueue.main.async {
                self.downloading = false
                if let err {
                    self.status = "下载失败：\(err.localizedDescription)"
                    return
                }
                guard let tempURL else { return }
                do {
                    let fm = FileManager.default
                    let workDir = fm.temporaryDirectory.appendingPathComponent("whim-update-\(UUID().uuidString)")
                    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                    let zipPath = workDir.appendingPathComponent(asset.name)
                    try fm.moveItem(at: tempURL, to: zipPath)

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

                    let currentApp = Bundle.main.bundleURL
                    if currentApp.pathExtension == "app" {
                        let script = """
                        sleep 1
                        rm -rf "\(currentApp.path)"
                        mv "\(newApp.path)" "\(currentApp.path)"
                        open "\(currentApp.path)"
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
        }.resume()
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
    @StateObject private var updater = GitHubUpdater()
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
                }
                .buttonStyle(.plain)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("GitHub Release 在线更新")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FlomoPalette.textPrimary(scheme))
                Text(updater.status)
                    .font(.system(size: 12))
                    .foregroundColor(FlomoPalette.textSecondary(scheme))

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
                Button(updater.checking ? "检查中..." : "检查更新") {
                    updater.checkForUpdates()
                }
                .disabled(updater.checking || updater.downloading)

                if updater.hasUpdate {
                    Button(updater.downloading ? "下载安装中..." : "一键更新并重启") {
                        updater.downloadAndInstall()
                    }
                    .disabled(updater.downloading)
                    .buttonStyle(.borderedProminent)
                    .tint(FlomoPalette.accent(scheme))
                }

                Spacer()

                Button("打开 GitHub") {
                    if let url = URL(string: "https://github.com/\(GitHubUpdater.repo)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(FlomoPalette.tagText(scheme))
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(FlomoPalette.card(scheme))
        .preferredColorScheme(.dark)
    }
}
