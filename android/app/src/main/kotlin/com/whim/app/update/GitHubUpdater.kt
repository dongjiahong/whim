package com.whim.app.update

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

@Serializable
data class ReleaseAsset(
    val name: String,
    @SerialName("browser_download_url") val browserDownloadUrl: String,
    val size: Long = 0
)

@Serializable
data class ReleaseInfo(
    @SerialName("tag_name") val tagName: String,
    val name: String = "",
    val body: String = "",
    @SerialName("html_url") val htmlUrl: String = "",
    val assets: List<ReleaseAsset> = emptyList()
)

data class UpdateCheckResult(
    val hasUpdate: Boolean,
    val message: String,
    val release: ReleaseInfo? = null
)

object GitHubUpdater {
    const val REPO = "dongjiahong/whim"
    const val CURRENT_VERSION = "0.1.3"

    private val json = Json { ignoreUnknownKeys = true }

    suspend fun checkLatest(): UpdateCheckResult = withContext(Dispatchers.IO) {
        runCatching {
            val conn = (URL("https://api.github.com/repos/$REPO/releases/latest").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 8000
                readTimeout = 8000
                setRequestProperty("Accept", "application/vnd.github+json")
                setRequestProperty("User-Agent", "Whim-Android/$CURRENT_VERSION")
            }
            val code = conn.responseCode
            if (code == 404) {
                return@withContext UpdateCheckResult(false, "当前已是最新版本（仓库暂未发布 Release）")
            }
            if (code !in 200..299) {
                return@withContext UpdateCheckResult(false, "检查失败：HTTP $code")
            }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val rel = json.decodeFromString<ReleaseInfo>(body)
            val remoteVer = rel.tagName.trimStart('v', 'V', ' ')
            if (isNewer(remoteVer, CURRENT_VERSION)) {
                UpdateCheckResult(true, "发现新版本 ${rel.tagName}", rel)
            } else {
                UpdateCheckResult(false, "当前已是最新版本 (v$CURRENT_VERSION)", rel)
            }
        }.getOrElse {
            UpdateCheckResult(false, "检查失败：${it.message ?: "网络异常"}")
        }
    }

    suspend fun downloadAndInstallApk(context: Context, release: ReleaseInfo): String = withContext(Dispatchers.IO) {
        val asset = release.assets.firstOrNull { it.name.endsWith(".apk", ignoreCase = true) }
            ?: return@withContext "该 Release 未包含 APK 安装包"

        runCatching {
            val updatesDir = File(context.cacheDir, "updates").apply { mkdirs() }
            val apkFile = File(updatesDir, "Whim-Android.apk")
            val conn = (URL(asset.browserDownloadUrl).openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = true
                connectTimeout = 15000
                readTimeout = 30000
            }
            conn.inputStream.use { input ->
                apkFile.outputStream().use { output -> input.copyTo(output) }
            }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", apkFile)
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(installIntent)
            "下载完成，正在拉起系统安装器..."
        }.getOrElse {
            "下载安装失败：${it.message ?: "未知错误"}"
        }
    }

    private fun isNewer(remote: String, current: String): Boolean {
        val r = remote.split(".").mapNotNull { it.toIntOrNull() }
        val c = current.split(".").mapNotNull { it.toIntOrNull() }
        val maxLen = maxOf(r.size, c.size)
        for (i in 0 until maxLen) {
            val rv = r.getOrElse(i) { 0 }
            val cv = c.getOrElse(i) { 0 }
            if (rv != cv) return rv > cv
        }
        return false
    }
}
