package com.whim.app.ui

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.NightsStay
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.WbSunny
import androidx.compose.material.icons.rounded.WbTwilight
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.whim.app.capture.WhimWidgetProvider
import com.whim.app.core.WhimBackupInfo
import com.whim.app.core.WhimCoreBridge
import com.whim.app.core.WhimDiscoveredPeer
import com.whim.app.core.WhimSyncHealthStatus
import com.whim.app.core.WhimSyncPeer
import com.whim.app.review.DailyReviewReceiver
import com.whim.app.review.DailyReviewScheduler
import com.whim.app.review.ReviewReminder
import com.whim.app.ui.theme.WhimTheme
import com.whim.app.update.GitHubUpdater
import com.whim.app.update.ReleaseInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Calendar
import java.util.Locale

enum class SettingsFocusSection {
    ALL,
    REVIEW,
    SYNC,
    ABOUT
}

private enum class SettingsPage {
    HOME,
    REMINDERS,
    SYNC,
    STORAGE,
    ABOUT
}

@Composable
fun MobileSettingsScreen(
    focusSection: SettingsFocusSection = SettingsFocusSection.ALL,
    themeMode: String,
    onThemeModeChange: (String) -> Unit,
    reviewReminders: List<ReviewReminder>,
    onReviewRemindersChange: (List<ReviewReminder>) -> Unit,
    notifPermissionGranted: Boolean,
    exactAlarmGranted: Boolean,
    onRequestNotificationPermission: () -> Unit,
    pairedPeers: List<WhimSyncPeer>,
    onPairedPeersUpdated: (List<WhimSyncPeer>) -> Unit,
    syncHealth: WhimSyncHealthStatus,
    onSyncHealthUpdated: (WhimSyncHealthStatus) -> Unit,
    initialRelease: ReleaseInfo? = null,
    onUpdateBadgeDismissed: () -> Unit = {},
    onSyncCompleted: () -> Unit,
    onBack: () -> Unit
) {
    val c = WhimTheme.colors
    val context = LocalContext.current

    val initialPage = remember(focusSection) {
        when (focusSection) {
            SettingsFocusSection.REVIEW -> SettingsPage.REMINDERS
            SettingsFocusSection.SYNC -> SettingsPage.SYNC
            SettingsFocusSection.ABOUT -> SettingsPage.ABOUT
            SettingsFocusSection.ALL -> SettingsPage.HOME
        }
    }
    var currentPage by remember(focusSection) { mutableStateOf(initialPage) }
    val openedDirectlyOnSubpage = initialPage != SettingsPage.HOME

    var storageTotalBytes by remember { mutableStateOf(0L) }
    var storageDbBytes by remember { mutableStateOf(0L) }
    var storageBlobsBytes by remember { mutableStateOf(0L) }
    var storageBlobCount by remember { mutableStateOf(0) }
    var storageOrphanCount by remember { mutableStateOf(0) }
    var storageOrphanBytes by remember { mutableStateOf(0L) }
    var storageLoaded by remember { mutableStateOf(false) }
    var storageRefreshTick by remember { mutableStateOf(0) }

    var availableRelease by remember(initialRelease) { mutableStateOf(initialRelease) }

    LaunchedEffect(storageRefreshTick) {
        val usage = withContext(Dispatchers.IO) {
            computeAndroidStorageUsage(File(context.applicationContext.filesDir, "whim_data"))
        }
        val dry = runCatching { WhimCoreBridge.cleanupOrphanBlobs(minAgeSec = 0, dryRun = true) }.getOrNull()
        storageTotalBytes = usage.totalBytes
        storageDbBytes = usage.dbBytes
        storageBlobsBytes = usage.blobsBytes
        storageBlobCount = usage.blobCount
        storageOrphanCount = dry?.removedFiles ?: 0
        storageOrphanBytes = dry?.freedBytes ?: 0L
        storageLoaded = true
    }

    fun navigateBack() {
        if (currentPage == SettingsPage.HOME || (openedDirectlyOnSubpage && currentPage == initialPage)) {
            onBack()
        } else {
            currentPage = SettingsPage.HOME
        }
    }

    BackHandler { navigateBack() }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(c.canvas)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
    ) {
        AnimatedContent(
            targetState = currentPage,
            transitionSpec = {
                val forward = targetState != SettingsPage.HOME
                if (forward) {
                    (slideInHorizontally { it / 4 } + fadeIn()) togetherWith (slideOutHorizontally { -it / 6 } + fadeOut())
                } else {
                    (slideInHorizontally { -it / 4 } + fadeIn()) togetherWith (slideOutHorizontally { it / 6 } + fadeOut())
                }
            },
            label = "settings_page_nav"
        ) { page ->
            when (page) {
                SettingsPage.HOME -> SettingsHomePage(
                    themeMode = themeMode,
                    onThemeModeChange = onThemeModeChange,
                    reviewReminders = reviewReminders,
                    pairedPeers = pairedPeers,
                    syncHealth = syncHealth,
                    storageLoaded = storageLoaded,
                    storageTotalBytes = storageTotalBytes,
                    storageOrphanCount = storageOrphanCount,
                    hasUpdate = availableRelease != null,
                    onNavigate = { currentPage = it },
                    onBack = onBack
                )

                SettingsPage.REMINDERS -> RemindersSubPage(
                    reminders = reviewReminders,
                    onRemindersChange = onReviewRemindersChange,
                    notifPermissionGranted = notifPermissionGranted,
                    exactAlarmGranted = exactAlarmGranted,
                    onRequestNotificationPermission = onRequestNotificationPermission,
                    onBack = { navigateBack() }
                )

                SettingsPage.SYNC -> SyncSubPage(
                    pairedPeers = pairedPeers,
                    onPairedPeersUpdated = onPairedPeersUpdated,
                    syncHealth = syncHealth,
                    onSyncHealthUpdated = onSyncHealthUpdated,
                    onSyncCompleted = onSyncCompleted,
                    onBack = { navigateBack() }
                )

                SettingsPage.STORAGE -> StorageSubPage(
                    storageLoaded = storageLoaded,
                    totalBytes = storageTotalBytes,
                    dbBytes = storageDbBytes,
                    blobsBytes = storageBlobsBytes,
                    blobCount = storageBlobCount,
                    orphanCount = storageOrphanCount,
                    orphanBytes = storageOrphanBytes,
                    onRefresh = { storageRefreshTick++ },
                    onBack = { navigateBack() }
                )

                SettingsPage.ABOUT -> AboutSubPage(
                    availableRelease = availableRelease,
                    onReleaseChanged = { availableRelease = it },
                    onUpdateBadgeDismissed = onUpdateBadgeDismissed,
                    onBack = { navigateBack() }
                )
            }
        }
    }
}

// MARK: - Top Bar

@Composable
private fun SettingsTopBar(
    title: String,
    onBack: () -> Unit,
    trailing: (@Composable () -> Unit)? = null
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(10.dp))
                .clickable(onClick = onBack)
                .padding(horizontal = 6.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Icon(
                Icons.Rounded.ChevronLeft,
                contentDescription = "返回",
                tint = c.textPrimary,
                modifier = Modifier.size(24.dp)
            )
            Text(title, style = t.title, color = c.textPrimary)
        }
        trailing?.invoke()
    }
}

// MARK: - 1. Settings Home Page

@Composable
private fun SettingsHomePage(
    themeMode: String,
    onThemeModeChange: (String) -> Unit,
    reviewReminders: List<ReviewReminder>,
    pairedPeers: List<WhimSyncPeer>,
    syncHealth: WhimSyncHealthStatus,
    storageLoaded: Boolean,
    storageTotalBytes: Long,
    storageOrphanCount: Int,
    hasUpdate: Boolean,
    onNavigate: (SettingsPage) -> Unit,
    onBack: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val enabledReminders = reviewReminders.filter { it.enabled && it.weekdays.isNotEmpty() }
    val onlinePeers = syncHealth.onlinePeers

    Column(modifier = Modifier.fillMaxSize()) {
        SettingsTopBar(title = "设置", onBack = onBack)

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp)
        ) {
            // Overview Hero Card
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(c.card)
                    .border(0.8.dp, c.border, RoundedCornerShape(16.dp))
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(c.accent),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Rounded.AutoAwesome,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(22.dp)
                        )
                    }
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Text("Whim", style = t.title, color = c.textPrimary)
                            Box(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(c.accent.copy(alpha = 0.16f))
                                    .padding(horizontal = 8.dp, vertical = 2.dp)
                            ) {
                                Text(
                                    "v${GitHubUpdater.CURRENT_VERSION}",
                                    fontSize = 11.sp,
                                    fontFamily = FontFamily.Monospace,
                                    fontWeight = FontWeight.Medium,
                                    color = c.accent
                                )
                            }
                        }
                        Text("本地优先闪念笔记 · 数据常驻本机", style = t.meta, color = c.textSecondary)
                    }
                }

                // Quick Status Strip (2 clickable pills)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    StatusQuickPill(
                        modifier = Modifier.weight(1f),
                        dotColor = if (enabledReminders.isNotEmpty()) c.accent else c.textMuted,
                        label = "每日提醒",
                        value = if (enabledReminders.isNotEmpty()) "${enabledReminders.size} 个已开启" else "已关闭",
                        onClick = { onNavigate(SettingsPage.REMINDERS) }
                    )
                    StatusQuickPill(
                        modifier = Modifier.weight(1f),
                        dotColor = when {
                            onlinePeers > 0 -> Color(0xFF34D399)
                            pairedPeers.isNotEmpty() -> c.accent
                            else -> c.textMuted
                        },
                        label = "局域网同步",
                        value = when {
                            onlinePeers > 0 -> "$onlinePeers 台在线"
                            pairedPeers.isNotEmpty() -> "已配对 ${pairedPeers.size} 台"
                            else -> "未配对"
                        },
                        onClick = { onNavigate(SettingsPage.SYNC) }
                    )
                }
            }

            // Visual Theme Selector
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SettingsGroupHeader("外观主题")
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(c.card)
                        .border(0.8.dp, c.border, RoundedCornerShape(14.dp))
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    MobileThemePreviewCard(
                        modifier = Modifier.weight(1f),
                        mode = "system",
                        label = "跟随系统",
                        selected = themeMode == "system",
                        onClick = { onThemeModeChange("system") }
                    )
                    MobileThemePreviewCard(
                        modifier = Modifier.weight(1f),
                        mode = "light",
                        label = "浅色",
                        selected = themeMode == "light",
                        onClick = { onThemeModeChange("light") }
                    )
                    MobileThemePreviewCard(
                        modifier = Modifier.weight(1f),
                        mode = "dark",
                        label = "深色",
                        selected = themeMode == "dark",
                        onClick = { onThemeModeChange("dark") }
                    )
                }
            }

            // Group 1: Reminders & Sync
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SettingsGroupHeader("提醒与同步")
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(c.card)
                        .border(0.8.dp, c.border, RoundedCornerShape(14.dp))
                ) {
                    SettingsNavRow(
                        icon = Icons.Rounded.Notifications,
                        iconBg = Color(0xFFE5A03D).copy(alpha = 0.16f),
                        iconTint = Color(0xFFE5A03D),
                        title = "每日提醒",
                        subtitle = "支持设置多个早晚复盘与总结闹钟",
                        value = DailyReviewScheduler.formatSummary(reviewReminders),
                        onClick = { onNavigate(SettingsPage.REMINDERS) }
                    )
                    SettingsInsetDivider()
                    SettingsNavRow(
                        icon = Icons.Rounded.Sync,
                        iconBg = c.accent.copy(alpha = 0.16f),
                        iconTint = c.accent,
                        title = "局域网同步",
                        subtitle = "支持同时配对多台 Mac 独立同步",
                        value = if (pairedPeers.isNotEmpty()) "已配对 ${pairedPeers.size} 台" else "去配对",
                        showDot = onlinePeers > 0,
                        dotColor = Color(0xFF34D399),
                        onClick = { onNavigate(SettingsPage.SYNC) }
                    )
                }
            }

            // Group 2: Data & About
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SettingsGroupHeader("数据与关于")
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(c.card)
                        .border(0.8.dp, c.border, RoundedCornerShape(14.dp))
                ) {
                    SettingsNavRow(
                        icon = Icons.Rounded.Storage,
                        iconBg = c.tagText.copy(alpha = 0.15f),
                        iconTint = c.tagText,
                        title = "存储与清理",
                        subtitle = if (storageOrphanCount > 0) "发现 $storageOrphanCount 张冗余图片可清理" else "查看数据库与本地图片占用",
                        value = if (storageLoaded) formatStorageBytes(storageTotalBytes) else "--",
                        showDot = storageOrphanCount > 0,
                        dotColor = Color(0xFFE5A03D),
                        onClick = { onNavigate(SettingsPage.STORAGE) }
                    )
                    SettingsInsetDivider()
                    SettingsNavRow(
                        icon = Icons.Rounded.Info,
                        iconBg = c.textSecondary.copy(alpha = 0.14f),
                        iconTint = c.textSecondary,
                        title = "关于与更新",
                        subtitle = if (hasUpdate) "发现 GitHub 新版本" else "检查新版本与更新日志",
                        value = "v${GitHubUpdater.CURRENT_VERSION}",
                        showDot = hasUpdate,
                        dotColor = Color(0xFFEF4444),
                        onClick = { onNavigate(SettingsPage.ABOUT) }
                    )
                }
            }

            Text(
                text = "所有笔记与图片均存储于本机，无云端账号依赖",
                style = t.meta,
                color = c.textMuted,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp, bottom = 24.dp)
            )
        }
    }
}

@Composable
private fun StatusQuickPill(
    modifier: Modifier = Modifier,
    dotColor: Color,
    label: String,
    value: String,
    onClick: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(c.canvas)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(6.5.dp)
                    .clip(CircleShape)
                    .background(dotColor)
            )
            Text(label, style = t.meta, color = c.textSecondary)
        }
        Text(
            value,
            style = t.body,
            fontWeight = FontWeight.SemiBold,
            color = c.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun MobileThemePreviewCard(
    modifier: Modifier = Modifier,
    mode: String,
    label: String,
    selected: Boolean,
    onClick: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(if (selected) c.accent.copy(alpha = 0.14f) else c.canvas)
            .border(
                width = if (selected) 1.5.dp else 0.8.dp,
                color = if (selected) c.accent else c.border,
                shape = RoundedCornerShape(10.dp)
            )
            .clickable(onClick = onClick)
            .padding(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(7.dp)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp)
                .clip(RoundedCornerShape(6.dp))
                .border(0.6.dp, c.border, RoundedCornerShape(6.dp))
        ) {
            when (mode) {
                "light" -> MiniPhoneMock(isDark = false, accent = c.accent)
                "dark" -> MiniPhoneMock(isDark = true, accent = c.accent)
                else -> Row(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f).fillMaxHeight()) { MiniPhoneMock(isDark = false, accent = c.accent) }
                    Box(Modifier.weight(1f).fillMaxHeight()) { MiniPhoneMock(isDark = true, accent = c.accent) }
                }
            }
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                label,
                style = t.meta,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                color = if (selected) c.accent else c.textPrimary
            )
            if (selected) {
                Icon(
                    Icons.Rounded.CheckCircle,
                    contentDescription = null,
                    tint = c.accent,
                    modifier = Modifier.size(13.dp)
                )
            }
        }
    }
}

@Composable
private fun MiniPhoneMock(isDark: Boolean, accent: Color) {
    val bg = if (isDark) Color(0xFF141414) else Color(0xFFF3F3F3)
    val card = if (isDark) Color(0xFF222222) else Color.White
    val line = if (isDark) Color(0x33FFFFFF) else Color(0x22000000)
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(bg)
            .padding(6.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(0.55f)
                .height(5.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(accent)
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(14.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(card)
                .padding(3.dp)
        ) {
            Box(Modifier.fillMaxWidth(0.7f).height(3.dp).background(line))
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(12.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(card)
        )
    }
}

@Composable
private fun SettingsGroupHeader(title: String) {
    val c = WhimTheme.colors
    Text(
        text = title,
        fontSize = 12.sp,
        fontWeight = FontWeight.Medium,
        color = c.textMuted,
        modifier = Modifier.padding(horizontal = 6.dp)
    )
}

@Composable
private fun SettingsInsetDivider() {
    val c = WhimTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 58.dp, end = 14.dp)
            .height(0.7.dp)
            .background(c.border)
    )
}

@Composable
private fun SettingsNavRow(
    icon: ImageVector,
    iconBg: Color,
    iconTint: Color,
    title: String,
    subtitle: String,
    value: String,
    showDot: Boolean = false,
    dotColor: Color = Color(0xFFEF4444),
    onClick: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(iconBg),
            contentAlignment = Alignment.Center
        ) {
            Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(18.dp))
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Text(title, style = t.body, fontWeight = FontWeight.Medium, color = c.textPrimary)
            Text(subtitle, style = t.meta, color = c.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            if (showDot) {
                Box(
                    modifier = Modifier
                        .size(7.dp)
                        .clip(CircleShape)
                        .background(dotColor)
                )
            }
            Text(value, style = t.meta, color = c.textSecondary)
            Icon(
                Icons.Rounded.ChevronRight,
                contentDescription = null,
                tint = c.textMuted,
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

// MARK: - 2. Multi-Reminder Clocks Sub-Page

@Composable
private fun RemindersSubPage(
    reminders: List<ReviewReminder>,
    onRemindersChange: (List<ReviewReminder>) -> Unit,
    notifPermissionGranted: Boolean,
    exactAlarmGranted: Boolean,
    onRequestNotificationPermission: () -> Unit,
    onBack: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var editingReminder by remember { mutableStateOf<ReviewReminder?>(null) }
    var isCreatingNew by remember { mutableStateOf(false) }
    var statusMessage by remember { mutableStateOf("") }
    // Entering RemindersSubPage must NEVER auto-open any reminder editor
    LaunchedEffect(Unit) {
        editingReminder = null
        isCreatingNew = false
    }
    val batteryUnrestricted = remember(reminders) { DailyReviewScheduler.isIgnoringBatteryOptimizations(context) }
    val nextTriggerText = remember(reminders) { DailyReviewScheduler.nextTriggerSummary(context) }

    val hasMorning = reminders.any { it.hour in 5..11 }
    val hasEvening = reminders.any { it.hour >= 18 || it.hour < 5 }

    Column(modifier = Modifier.fillMaxSize()) {
        SettingsTopBar(
            title = "每日提醒",
            onBack = onBack,
            trailing = {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(20.dp))
                        .background(c.accent)
                        .clickable {
                            val defaultHour = if (hasEvening && !hasMorning) 8 else if (hasMorning && !hasEvening) 21 else 12
                            val defaultLabel = when (defaultHour) {
                                8 -> "晨间复盘"
                                21 -> "晚间总结"
                                else -> "午后回顾"
                            }
                            isCreatingNew = true
                            editingReminder = ReviewReminder(
                                label = defaultLabel,
                                hour = defaultHour,
                                minute = 30,
                                weekdays = ReviewReminder.ALL_WEEKDAYS,
                                enabled = true,
                                skipIfEmpty = false
                            )
                        }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(Icons.Rounded.Add, contentDescription = "添加提醒", tint = Color.White, modifier = Modifier.size(16.dp))
                    Text("添加", style = t.meta, fontWeight = FontWeight.SemiBold, color = Color.White)
                }
            }
        )

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            if (!nextTriggerText.isNullOrBlank()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(c.accent.copy(alpha = 0.10f))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Box(Modifier.size(6.dp).clip(CircleShape).background(c.accent))
                    Text(nextTriggerText, style = t.meta, color = c.accent, fontWeight = FontWeight.Medium)
                }
            }

            // Permission & battery reliability banner (only when needed)
            if (!notifPermissionGranted || (!exactAlarmGranted && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) || !batteryUnrestricted) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color(0xFFE5A03D).copy(alpha = 0.12f))
                        .border(0.8.dp, Color(0xFFE5A03D).copy(alpha = 0.35f), RoundedCornerShape(12.dp))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    if (!notifPermissionGranted) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("未开启系统通知权限，无法弹出提醒", style = t.meta, color = c.textPrimary)
                            Text(
                                "去开启",
                                style = t.meta,
                                fontWeight = FontWeight.SemiBold,
                                color = Color(0xFFE5A03D),
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .clickable { onRequestNotificationPermission() }
                                    .padding(horizontal = 6.dp, vertical = 3.dp)
                            )
                        }
                    }
                    if (!exactAlarmGranted && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("未授予精确闹钟权限，息屏可能延迟", style = t.meta, color = c.textPrimary)
                            Text(
                                "去授权",
                                style = t.meta,
                                fontWeight = FontWeight.SemiBold,
                                color = Color(0xFFE5A03D),
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .clickable {
                                        runCatching {
                                            val i = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                                                data = Uri.parse("package:${context.packageName}")
                                            }
                                            context.startActivity(i)
                                        }
                                    }
                                    .padding(horizontal = 6.dp, vertical = 3.dp)
                            )
                        }
                    }
                    if (!batteryUnrestricted) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("未设为省电无限制，国产系统杀后台可能延迟", style = t.meta, color = c.textPrimary, modifier = Modifier.weight(1f))
                            Text(
                                "去设置",
                                style = t.meta,
                                fontWeight = FontWeight.SemiBold,
                                color = Color(0xFFE5A03D),
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .clickable {
                                        val opened = runCatching {
                                            val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                                data = Uri.parse("package:${context.packageName}")
                                            }
                                            context.startActivity(i)
                                            true
                                        }.getOrDefault(false)
                                        if (!opened) {
                                            runCatching {
                                                val i = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                                    data = Uri.parse("package:${context.packageName}")
                                                }
                                                context.startActivity(i)
                                            }
                                        }
                                    }
                                    .padding(horizontal = 6.dp, vertical = 3.dp)
                            )
                        }
                    }
                }
            }

            if (reminders.isEmpty()) {
                // Empty state with quick presets
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(c.card)
                        .border(0.8.dp, c.border, RoundedCornerShape(16.dp))
                        .padding(horizontal = 20.dp, vertical = 28.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Icon(
                        Icons.Rounded.Notifications,
                        contentDescription = null,
                        tint = c.textMuted,
                        modifier = Modifier.size(34.dp)
                    )
                    Text("还没有设置提醒时钟", style = t.section, color = c.textPrimary)
                    Text(
                        "支持同时设置多个时间点，例如每晚总结、次日清晨复盘。",
                        style = t.meta,
                        color = c.textSecondary,
                        textAlign = TextAlign.Center
                    )
                    Spacer(Modifier.height(4.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        QuickReminderSuggestionChip(
                            icon = Icons.Rounded.WbTwilight,
                            label = "08:30 晨间复盘",
                            onClick = {
                                val next = DailyReviewScheduler.addReminder(
                                    context,
                                    ReviewReminder(label = "晨间复盘", hour = 8, minute = 30)
                                )
                                onRemindersChange(next)
                                statusMessage = "已添加：每天 08:30 晨间复盘"
                            }
                        )
                        QuickReminderSuggestionChip(
                            icon = Icons.Rounded.NightsStay,
                            label = "21:30 晚间总结",
                            onClick = {
                                val next = DailyReviewScheduler.addReminder(
                                    context,
                                    ReviewReminder(label = "晚间总结", hour = 21, minute = 30)
                                )
                                onRemindersChange(next)
                                statusMessage = "已添加：每天 21:30 晚间总结"
                            }
                        )
                    }
                }
            } else {
                reminders.forEach { reminder ->
                    ReminderClockMobileCard(
                        reminder = reminder,
                        onEdit = {
                            isCreatingNew = false
                            editingReminder = reminder
                        },
                        onToggle = {
                            val next = DailyReviewScheduler.toggleReminder(context, reminder.id)
                            onRemindersChange(next)
                            statusMessage = DailyReviewScheduler.formatSummary(next)
                        }
                    )
                }

                // Helpful 1-tap suggestion when user only has morning or only evening
                if (reminders.size < 2) {
                    if (!hasMorning) {
                        QuickAddBannerCard(
                            icon = Icons.Rounded.WbTwilight,
                            title = "添加晨间复盘提醒",
                            time = "08:30",
                            onClick = {
                                val next = DailyReviewScheduler.addReminder(
                                    context,
                                    ReviewReminder(label = "晨间复盘", hour = 8, minute = 30)
                                )
                                onRemindersChange(next)
                                statusMessage = "已添加晨间复盘（08:30），点击卡片可微调"
                            }
                        )
                    }
                    if (!hasEvening) {
                        QuickAddBannerCard(
                            icon = Icons.Rounded.NightsStay,
                            title = "添加晚间总结提醒",
                            time = "21:30",
                            onClick = {
                                val next = DailyReviewScheduler.addReminder(
                                    context,
                                    ReviewReminder(label = "晚间总结", hour = 21, minute = 30)
                                )
                                onRemindersChange(next)
                                statusMessage = "已添加晚间总结（21:30），点击卡片可微调"
                            }
                        )
                    }
                }
            }

            if (statusMessage.isNotEmpty()) {
                Text(
                    statusMessage,
                    style = t.meta,
                    color = c.accent,
                    modifier = Modifier.padding(horizontal = 4.dp)
                )
            }

            // Quiet footer utility bar
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(c.card)
                    .border(0.8.dp, c.border, RoundedCornerShape(14.dp))
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(9.dp))
                            .background(c.canvas)
                            .clickable {
                                scope.launch {
                                    val cnt = withContext(Dispatchers.IO) {
                                        runCatching { WhimCoreBridge.countTodayNotesBlocking() }.getOrDefault(0)
                                    }
                                    val first = reminders.firstOrNull { it.enabled } ?: reminders.firstOrNull()
                                    val sent = DailyReviewReceiver.postNotification(
                                        context = context,
                                        count = cnt,
                                        label = first?.displayTitle() ?: "每日复盘",
                                        hour = first?.hour ?: 21,
                                        isTest = true
                                    )
                                    statusMessage = if (sent) {
                                        "测试通知已发送，可在通知栏点击「去复盘」或「30 分钟后再提醒」"
                                    } else {
                                        "未获得通知权限，请先允许 Whim 发送系统通知"
                                    }
                                }
                            }
                            .padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("发送测试通知", style = t.meta, fontWeight = FontWeight.Medium, color = c.textPrimary)
                    }
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(9.dp))
                            .background(c.canvas)
                            .clickable {
                                runCatching {
                                    val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                        putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                                    }
                                    context.startActivity(i)
                                }
                            }
                            .padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text("系统通知设置", style = t.meta, fontWeight = FontWeight.Medium, color = c.textSecondary)
                    }
                }
                Text(
                    "通过 Android AlarmManager 系统闹钟托管，杀进程或重启手机后依然准时送达。点击提醒卡片可编辑名称、时间与重复周期。",
                    style = t.meta,
                    color = c.textMuted
                )
            }

            Spacer(Modifier.height(24.dp))
        }
    }

    // Reminder Editor Dialog
    editingReminder?.let { target ->
        ReminderEditorDialog(
            initial = target,
            isNew = isCreatingNew,
            onDismiss = { editingReminder = null },
            onSave = { updated ->
                val next = if (isCreatingNew) {
                    DailyReviewScheduler.addReminder(context, updated)
                } else {
                    DailyReviewScheduler.updateReminder(context, updated)
                }
                onRemindersChange(next)
                statusMessage = "已保存：${updated.displayTitle()} · ${updated.repeatSummary()} ${updated.formattedTime()}"
                editingReminder = null
            },
            onDelete = if (!isCreatingNew) {
                {
                    val next = DailyReviewScheduler.deleteReminder(context, target.id)
                    onRemindersChange(next)
                    statusMessage = "已删除「${target.displayTitle()}」"
                    editingReminder = null
                }
            } else null
        )
    }
}

@Composable
private fun ReminderClockMobileCard(
    reminder: ReviewReminder,
    onEdit: () -> Unit,
    onToggle: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val iconAndColor = when (reminder.hour) {
        in 5..11 -> Icons.Rounded.WbTwilight to Color(0xFFE5A03D)
        in 12..17 -> Icons.Rounded.WbSunny to c.tagText
        else -> Icons.Rounded.NightsStay to c.accent
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(c.card)
            .border(0.8.dp, c.border, RoundedCornerShape(14.dp))
            .clickable(onClick = onEdit)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Box(
            modifier = Modifier
                .size(42.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(if (reminder.enabled) iconAndColor.second.copy(alpha = 0.16f) else c.canvas),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                iconAndColor.first,
                contentDescription = null,
                tint = if (reminder.enabled) iconAndColor.second else c.textMuted,
                modifier = Modifier.size(20.dp)
            )
        }

        Column(
            modifier = Modifier
                .weight(1f)
                .alpha(if (reminder.enabled) 1f else 0.55f),
            verticalArrangement = Arrangement.spacedBy(3.dp)
        ) {
            Row(
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    text = reminder.formattedTime(),
                    fontSize = 26.sp,
                    fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace,
                    color = c.textPrimary
                )
                Text(
                    text = reminder.displayTitle(),
                    style = t.body,
                    fontWeight = FontWeight.Medium,
                    color = c.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(bottom = 3.dp)
                )
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(reminder.repeatSummary(), style = t.meta, color = c.textSecondary)
                if (reminder.skipIfEmpty) {
                    Text(
                        "· 无笔记时跳过",
                        style = t.meta,
                        color = c.textMuted
                    )
                }
            }
        }

        Switch(
            checked = reminder.enabled,
            onCheckedChange = { onToggle() },
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = c.accent
            )
        )
    }
}

@Composable
private fun QuickReminderSuggestionChip(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(c.canvas)
            .border(0.8.dp, c.border, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Icon(icon, contentDescription = null, tint = c.accent, modifier = Modifier.size(15.dp))
        Text(label, style = t.meta, fontWeight = FontWeight.Medium, color = c.textPrimary)
    }
}

@Composable
private fun QuickAddBannerCard(
    icon: ImageVector,
    title: String,
    time: String,
    onClick: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(c.card.copy(alpha = 0.65f))
            .border(0.8.dp, c.accent.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Icon(icon, contentDescription = null, tint = c.accent, modifier = Modifier.size(18.dp))
        Text(title, style = t.body, color = c.textPrimary, modifier = Modifier.weight(1f))
        Text(time, style = t.meta, fontFamily = FontFamily.Monospace, color = c.textSecondary)
        Icon(Icons.Rounded.Add, contentDescription = null, tint = c.accent, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun ReminderEditorDialog(
    initial: ReviewReminder,
    isNew: Boolean,
    onDismiss: () -> Unit,
    onSave: (ReviewReminder) -> Unit,
    onDelete: (() -> Unit)?
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current

    var label by remember(initial.id) { mutableStateOf(initial.label) }
    var hour by remember(initial.id) { mutableStateOf(initial.hour) }
    var minute by remember(initial.id) { mutableStateOf(initial.minute) }
    var weekdays by remember(initial.id) { mutableStateOf(initial.weekdays) }
    var skipIfEmpty by remember(initial.id) { mutableStateOf(initial.skipIfEmpty) }

    val labelPresets = listOf("晨间复盘", "午后回顾", "晚间总结", "睡前清空")
    val weekdayItems = listOf(
        Calendar.MONDAY to "一",
        Calendar.TUESDAY to "二",
        Calendar.WEDNESDAY to "三",
        Calendar.THURSDAY to "四",
        Calendar.FRIDAY to "五",
        Calendar.SATURDAY to "六",
        Calendar.SUNDAY to "日"
    )

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(c.card)
                .border(0.8.dp, c.border, RoundedCornerShape(18.dp))
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(if (isNew) "新建提醒时钟" else "编辑提醒时钟", style = t.title, color = c.textPrimary)
                if (onDelete != null) {
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .clickable(onClick = onDelete)
                            .padding(horizontal = 8.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Icon(
                            Icons.Rounded.DeleteOutline,
                            contentDescription = "删除",
                            tint = Color(0xFFE06C6C),
                            modifier = Modifier.size(16.dp)
                        )
                        Text("删除", style = t.meta, color = Color(0xFFE06C6C), fontWeight = FontWeight.Medium)
                    }
                }
            }

            // Custom Whim-styled Compose Wheel Time Picker (replaces native TimePickerDialog)
            WhimTimePicker(
                hour = hour,
                minute = minute,
                onTimeChange = { h, m ->
                    hour = h
                    minute = m
                }
            )

            // Label Input + Presets
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("提醒名称", style = t.meta, color = c.textSecondary)
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(c.canvas)
                        .padding(horizontal = 12.dp, vertical = 11.dp)
                ) {
                    BasicTextField(
                        value = label,
                        onValueChange = { label = it.take(18) },
                        singleLine = true,
                        textStyle = t.body.copy(color = c.textPrimary),
                        cursorBrush = SolidColor(c.accent),
                        modifier = Modifier.fillMaxWidth(),
                        decorationBox = { inner ->
                            if (label.isEmpty()) Text("例如：晨间复盘 / 晚间总结", style = t.body, color = c.textMuted)
                            inner()
                        }
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    labelPresets.forEach { preset ->
                        val active = label == preset
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(7.dp))
                                .background(if (active) c.accent else c.canvas)
                                .clickable { label = preset }
                                .padding(vertical = 6.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                preset,
                                fontSize = 11.sp,
                                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                                color = if (active) Color.White else c.textSecondary,
                                maxLines = 1
                            )
                        }
                    }
                }
            }

            // Repeat Weekdays
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("重复周期", style = t.meta, color = c.textSecondary)
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        listOf(
                            "每天" to ReviewReminder.ALL_WEEKDAYS,
                            "工作日" to ReviewReminder.WORKDAYS,
                            "周末" to ReviewReminder.WEEKENDS
                        ).forEach { (presetLabel, presetDays) ->
                            val active = weekdays == presetDays
                            Box(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(if (active) c.accent else c.canvas)
                                    .clickable { weekdays = presetDays }
                                    .padding(horizontal = 9.dp, vertical = 4.dp)
                            ) {
                                Text(presetLabel, style = t.meta, color = if (active) Color.White else c.textSecondary)
                            }
                        }
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    weekdayItems.forEach { (dayConst, dayLabel) ->
                        val selected = dayConst in weekdays
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(8.dp))
                                .background(if (selected) c.accent else c.canvas)
                                .clickable {
                                    weekdays = if (selected) {
                                        if (weekdays.size > 1) weekdays - dayConst else weekdays
                                    } else {
                                        weekdays + dayConst
                                    }
                                }
                                .padding(vertical = 9.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                dayLabel,
                                style = t.meta,
                                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                                color = if (selected) Color.White else c.textSecondary
                            )
                        }
                    }
                }
            }

            // Skip If Empty toggle
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(
                    modifier = Modifier.weight(1f).padding(end = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    Text("今日无笔记时不打扰", style = t.body, color = c.textPrimary)
                    Text("当天 0 条记录时跳过此次通知", style = t.meta, color = c.textSecondary)
                }
                Switch(
                    checked = skipIfEmpty,
                    onCheckedChange = { skipIfEmpty = it },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Color.White,
                        checkedTrackColor = c.accent
                    )
                )
            }

            // Actions
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(c.canvas)
                        .clickable(onClick = onDismiss)
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text("取消", style = t.body, color = c.textSecondary)
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(c.accent)
                        .clickable {
                            onSave(
                                initial.copy(
                                    label = label.trim(),
                                    hour = hour,
                                    minute = minute,
                                    weekdays = weekdays,
                                    enabled = true,
                                    skipIfEmpty = skipIfEmpty
                                )
                            )
                        }
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text("保存", style = t.body, fontWeight = FontWeight.SemiBold, color = Color.White)
                }
            }
        }
    }
}

// MARK: - 3. LAN Sync Sub-Page (Route B: Multi-Mac Independent Pairing + Bidirectional Unpair)

@Composable
private fun SyncSubPage(
    pairedPeers: List<WhimSyncPeer>,
    onPairedPeersUpdated: (List<WhimSyncPeer>) -> Unit,
    syncHealth: WhimSyncHealthStatus,
    onSyncHealthUpdated: (WhimSyncHealthStatus) -> Unit,
    onSyncCompleted: () -> Unit,
    onBack: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val syncPrefs = remember { context.getSharedPreferences("whim_sync_prefs", Context.MODE_PRIVATE) }

    var discoveredPeers by remember { mutableStateOf<List<WhimDiscoveredPeer>>(emptyList()) }
    var ignoredPeerIds by remember {
        mutableStateOf(syncPrefs.getStringSet("ignored_peer_ids", emptySet())?.toSet() ?: emptySet())
    }
    var pairingTarget by remember { mutableStateOf<WhimDiscoveredPeer?>(null) }
    var manualAddrInput by remember { mutableStateOf("") }
    var manualCodeInput by remember { mutableStateOf("") }
    var showManualAddr by remember { mutableStateOf(false) }
    var syncStatus by remember { mutableStateOf("") }
    var isScanning by remember { mutableStateOf(false) }
    var isSyncing by remember { mutableStateOf(false) }
    var isPairing by remember { mutableStateOf(false) }

    fun persistIgnored(next: Set<String>) {
        ignoredPeerIds = next
        syncPrefs.edit().putStringSet("ignored_peer_ids", next).apply()
    }

    suspend fun refreshAll(activeProbe: Boolean = false) {
        isScanning = true
        runCatching { onPairedPeersUpdated(WhimCoreBridge.listPairedPeers()) }
        runCatching { discoveredPeers = WhimCoreBridge.discoverLAN() }
        runCatching { onSyncHealthUpdated(WhimCoreBridge.checkSyncHealth(activeProbe = activeProbe)) }
        isScanning = false
    }

    LaunchedEffect(Unit) {
        refreshAll(activeProbe = true)
    }

    val liveById = remember(syncHealth.peers) { syncHealth.peers.associateBy { it.peerId } }
    val pairedIdSet = remember(pairedPeers) { pairedPeers.map { it.peerId }.toSet() }
    val visibleDiscovered = remember(discoveredPeers, pairedIdSet, ignoredPeerIds) {
        discoveredPeers.filter { it.peerId !in pairedIdSet && it.peerId !in ignoredPeerIds }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        SettingsTopBar(
            title = "局域网同步",
            onBack = onBack,
            trailing = {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .clickable(enabled = !isSyncing && !isScanning) {
                            scope.launch {
                                isSyncing = true
                                syncStatus = "正在扫描并同步已配对设备..."
                                val res = runCatching { WhimCoreBridge.syncOnce() }.getOrNull()
                                refreshAll(activeProbe = true)
                                isSyncing = false
                                syncStatus = when {
                                    res != null && res.peersSynced > 0 -> "已同步 ${res.peersSynced} 台设备" + if (res.notesMerged > 0) " · 合并 ${res.notesMerged} 条" else ""
                                    pairedPeers.isEmpty() -> "扫描完成"
                                    else -> "已完成刷新"
                                }
                                onSyncCompleted()
                                WhimWidgetProvider.refreshAll(context)
                            }
                        }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        Icons.Rounded.Refresh,
                        contentDescription = "刷新",
                        tint = if (isSyncing || isScanning) c.textMuted else c.tagText,
                        modifier = Modifier.size(16.dp)
                    )
                    Text(
                        if (isSyncing || isScanning) "扫描中" else "刷新",
                        style = t.meta,
                        fontWeight = FontWeight.Medium,
                        color = if (isSyncing || isScanning) c.textMuted else c.tagText
                    )
                }
            }
        )

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            if (syncStatus.isNotEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(c.accent.copy(alpha = 0.12f))
                        .padding(horizontal = 14.dp, vertical = 9.dp)
                ) {
                    Text(syncStatus, style = t.meta, color = c.accent)
                }
            }

            // Card 1: Paired Devices (Concurrent Multi-Mac Sync + Bidirectional Forget)
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(c.card)
                    .border(0.8.dp, c.border, RoundedCornerShape(16.dp))
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text("已配对设备", style = t.section, color = c.textPrimary)
                        if (pairedPeers.isNotEmpty()) {
                            Box(
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(c.accent.copy(alpha = 0.16f))
                                    .padding(horizontal = 7.dp, vertical = 1.dp)
                            ) {
                                Text(
                                    "${pairedPeers.size}",
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = c.accent
                                )
                            }
                        }
                    }
                    Text("每台独立配对码", style = t.meta, color = c.textMuted)
                }

                if (pairedPeers.isEmpty()) {
                    Text(
                        "尚未配对任何电脑。在下方「局域网发现」中点击要连接的 Mac 并输入它的 6 位配对码即可，支持同时配对多台 Mac。",
                        style = t.meta,
                        color = c.textSecondary
                    )
                } else {
                    pairedPeers.forEach { peer ->
                        val live = liveById[peer.peerId]
                        val isOnline = live?.online == true
                        val isWrongCode = live?.status == "wrong_code"
                        val dotColor = when {
                            isOnline -> Color(0xFF34D399)
                            isWrongCode -> Color(0xFFE5A03D)
                            else -> c.textMuted
                        }
                        val statusLabel = live?.message?.takeIf { it.isNotEmpty() } ?: if (isOnline) "在线" else "离线"

                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(11.dp))
                                .background(c.canvas)
                                .padding(horizontal = 12.dp, vertical = 11.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                modifier = Modifier.weight(1f)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(8.dp)
                                        .clip(CircleShape)
                                        .background(dotColor)
                                )
                                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text(
                                        peer.displayName.ifEmpty { "已配对电脑" },
                                        style = t.body,
                                        fontWeight = FontWeight.Medium,
                                        color = c.textPrimary,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        listOfNotNull(
                                            peer.lastAddr.takeIf { it.isNotEmpty() },
                                            statusLabel
                                        ).joinToString(" · "),
                                        style = t.meta,
                                        color = if (isOnline) c.accent else if (isWrongCode) Color(0xFFE5A03D) else c.textSecondary,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }
                            }
                            Box(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(Color(0xFFE06C6C).copy(alpha = 0.14f))
                                    .clickable {
                                        scope.launch {
                                            runCatching { WhimCoreBridge.removePairedPeer(peer.peerId) }
                                            refreshAll(activeProbe = false)
                                            syncStatus = "已断开与「${peer.displayName.ifEmpty { peer.peerId }}」的连接，双方已停止自动重连"
                                        }
                                    }
                                    .padding(horizontal = 11.dp, vertical = 6.dp)
                            ) {
                                Text("忘记", style = t.meta, fontWeight = FontWeight.Medium, color = Color(0xFFE06C6C))
                            }
                        }
                    }
                }
            }

            // Card 2: Nearby Discovered LAN Macs (Pair or Ignore)
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(c.card)
                    .border(0.8.dp, c.border, RoundedCornerShape(16.dp))
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("局域网发现", style = t.section, color = c.textPrimary)
                    Text(
                        if (isScanning) "扫描中..." else "重新扫描",
                        style = t.meta,
                        fontWeight = FontWeight.Medium,
                        color = if (isScanning) c.textMuted else c.tagText,
                        modifier = Modifier
                            .clip(RoundedCornerShape(6.dp))
                            .clickable(enabled = !isScanning) {
                                scope.launch { refreshAll(activeProbe = false) }
                            }
                            .padding(horizontal = 6.dp, vertical = 3.dp)
                    )
                }

                if (visibleDiscovered.isEmpty()) {
                    Text(
                        if (isScanning) "正在同一 Wi-Fi 下搜索 Whim 电脑..." else "暂未发现新的未配对电脑。请确认 Mac 端已打开 Whim 且与手机在同一 Wi-Fi。",
                        style = t.meta,
                        color = c.textMuted
                    )
                } else {
                    visibleDiscovered.forEach { peer ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(11.dp))
                                .background(c.canvas)
                                .padding(horizontal = 12.dp, vertical = 11.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                modifier = Modifier.weight(1f)
                            ) {
                                Icon(
                                    Icons.Rounded.Computer,
                                    contentDescription = null,
                                    tint = c.textSecondary,
                                    modifier = Modifier.size(18.dp)
                                )
                                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text(
                                        peer.displayName.ifEmpty { peer.addr },
                                        style = t.body,
                                        fontWeight = FontWeight.Medium,
                                        color = c.textPrimary,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        peer.addr,
                                        style = t.meta,
                                        fontFamily = FontFamily.Monospace,
                                        color = c.textMuted
                                    )
                                }
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(8.dp))
                                        .background(c.card)
                                        .border(0.8.dp, c.border, RoundedCornerShape(8.dp))
                                        .clickable { persistIgnored(ignoredPeerIds + peer.peerId) }
                                        .padding(horizontal = 10.dp, vertical = 6.dp)
                                ) {
                                    Text("忽略", style = t.meta, color = c.textSecondary)
                                }
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(8.dp))
                                        .background(c.accent)
                                        .clickable { pairingTarget = peer }
                                        .padding(horizontal = 12.dp, vertical = 6.dp)
                                ) {
                                    Text("配对", style = t.meta, fontWeight = FontWeight.SemiBold, color = Color.White)
                                }
                            }
                        }
                    }
                }

                if (ignoredPeerIds.isNotEmpty()) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("已忽略 ${ignoredPeerIds.size} 台局域网设备", style = t.meta, color = c.textMuted)
                        Text(
                            "恢复显示",
                            style = t.meta,
                            fontWeight = FontWeight.Medium,
                            color = c.tagText,
                            modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .clickable {
                                    persistIgnored(emptySet())
                                    scope.launch { refreshAll(activeProbe = false) }
                                }
                                .padding(horizontal = 6.dp, vertical = 3.dp)
                        )
                    }
                }
            }

            // Card 3: Collapsible Manual IP:Port + Remote Code Pairing
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(c.card)
                    .border(0.8.dp, c.border, RoundedCornerShape(14.dp))
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { showManualAddr = !showManualAddr }
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("找不到电脑？手动输入地址与配对码", style = t.meta, fontWeight = FontWeight.Medium, color = c.textSecondary)
                    Icon(
                        if (showManualAddr) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore,
                        contentDescription = null,
                        tint = c.textMuted,
                        modifier = Modifier.size(18.dp)
                    )
                }
                AnimatedVisibility(visible = showManualAddr) {
                    Column(
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("支持手动输入或粘贴 Mac 配对链接", style = t.meta, color = c.textMuted)
                            Text(
                                "粘贴配对码链接",
                                style = t.meta,
                                fontWeight = FontWeight.Medium,
                                color = c.accent,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .clickable {
                                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                                        val clipText = cm?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString().orEmpty().trim()
                                        val uri = runCatching { Uri.parse(clipText) }.getOrNull()
                                        if (uri != null && uri.scheme == "whim" && uri.host == "pair") {
                                            val addr = uri.getQueryParameter("addr").orEmpty()
                                            val code = uri.getQueryParameter("code").orEmpty().filter { it.isDigit() }.take(6)
                                            if (addr.isNotEmpty()) manualAddrInput = addr
                                            if (code.isNotEmpty()) manualCodeInput = code
                                            syncStatus = "已从剪贴板解析配对地址与配对码"
                                        } else {
                                            syncStatus = "剪贴板中未找到 whim://pair?... 配对链接"
                                        }
                                    }
                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                            )
                        }
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(9.dp))
                                .background(c.canvas)
                                .padding(horizontal = 12.dp, vertical = 10.dp)
                        ) {
                            BasicTextField(
                                value = manualAddrInput,
                                onValueChange = { manualAddrInput = it },
                                singleLine = true,
                                textStyle = t.body.copy(color = c.textPrimary, fontFamily = FontFamily.Monospace),
                                cursorBrush = SolidColor(c.accent),
                                modifier = Modifier.fillMaxWidth(),
                                decorationBox = { inner ->
                                    if (manualAddrInput.isEmpty()) Text("IP:端口（如 192.168.5.111:8788）", style = t.meta, color = c.textMuted)
                                    inner()
                                }
                            )
                        }
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(9.dp))
                                .background(c.canvas)
                                .padding(horizontal = 12.dp, vertical = 10.dp)
                        ) {
                            BasicTextField(
                                value = manualCodeInput,
                                onValueChange = { manualCodeInput = it.filter { ch -> ch.isDigit() }.take(6) },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                textStyle = t.body.copy(color = c.textPrimary, fontFamily = FontFamily.Monospace),
                                cursorBrush = SolidColor(c.accent),
                                modifier = Modifier.fillMaxWidth(),
                                decorationBox = { inner ->
                                    if (manualCodeInput.isEmpty()) Text("该电脑的 6 位配对码", style = t.meta, color = c.textMuted)
                                    inner()
                                }
                            )
                        }
                        val manualReady = manualAddrInput.trim().isNotEmpty() && manualCodeInput.length == 6 && !isPairing
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(if (manualReady) c.accent else c.canvas)
                                .clickable(enabled = manualReady) {
                                    val addr = manualAddrInput.trim()
                                    val code = manualCodeInput
                                    scope.launch {
                                        isPairing = true
                                        syncStatus = "正在连接 $addr 并验证配对码..."
                                        runCatching { WhimCoreBridge.pairAndSync(addr, code) }
                                            .onSuccess { res ->
                                                manualAddrInput = ""
                                                manualCodeInput = ""
                                                refreshAll(activeProbe = true)
                                                syncStatus = "配对成功" + if (res.notesMerged > 0) " · 合并 ${res.notesMerged} 条笔记" else " · 已保持同步"
                                                onSyncCompleted()
                                                WhimWidgetProvider.refreshAll(context)
                                            }
                                            .onFailure { syncStatus = it.message ?: "配对失败，请核对地址与配对码" }
                                        isPairing = false
                                    }
                                }
                                .padding(vertical = 11.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                if (isPairing) "正在配对..." else "配对并同步",
                                style = t.body,
                                fontWeight = FontWeight.SemiBold,
                                color = if (manualReady) Color.White else c.textMuted
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }

    // 6-Digit Segmented Code Dialog for pairing a specific discovered Mac
    pairingTarget?.let { target ->
        PairDeviceCodeDialog(
            peer = target,
            isPairing = isPairing,
            onDismiss = { if (!isPairing) pairingTarget = null },
            onConfirm = { code ->
                scope.launch {
                    isPairing = true
                    syncStatus = "正在配对「${target.displayName.ifEmpty { target.addr }}」..."
                    runCatching { WhimCoreBridge.pairAndSync(target.addr, code) }
                        .onSuccess { res ->
                            pairingTarget = null
                            refreshAll(activeProbe = true)
                            syncStatus = "已配对「${target.displayName.ifEmpty { target.addr }}」" + if (res.notesMerged > 0) " · 合并 ${res.notesMerged} 条" else ""
                            onSyncCompleted()
                            WhimWidgetProvider.refreshAll(context)
                        }
                        .onFailure { err ->
                            syncStatus = err.message ?: "配对码不正确"
                        }
                    isPairing = false
                }
            }
        )
    }
}

@Composable
private fun PairDeviceCodeDialog(
    peer: WhimDiscoveredPeer,
    isPairing: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    var codeInput by remember(peer.peerId) { mutableStateOf("") }
    val ready = codeInput.length == 6 && !isPairing

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(c.card)
                .border(0.8.dp, c.border, RoundedCornerShape(18.dp))
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("配对 ${peer.displayName.ifEmpty { peer.addr }}", style = t.title, color = c.textPrimary)
                Text(
                    "请输入该电脑「设置 → 局域网同步」中显示的 6 位专属配对码（${peer.addr}）。",
                    style = t.meta,
                    color = c.textSecondary
                )
            }

            BasicTextField(
                value = codeInput,
                onValueChange = { codeInput = it.filter { ch -> ch.isDigit() }.take(6) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                cursorBrush = SolidColor(Color.Transparent),
                textStyle = t.body.copy(color = Color.Transparent),
                modifier = Modifier.fillMaxWidth(),
                decorationBox = {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        for (i in 0 until 6) {
                            val ch = codeInput.getOrNull(i)?.toString() ?: ""
                            val isCurrent = i == codeInput.length
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .height(50.dp)
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(c.canvas)
                                    .border(
                                        width = if (isCurrent || ch.isNotEmpty()) 1.4.dp else 0.8.dp,
                                        color = when {
                                            isCurrent -> c.accent
                                            ch.isNotEmpty() -> c.accent.copy(alpha = 0.45f)
                                            else -> c.border
                                        },
                                        shape = RoundedCornerShape(10.dp)
                                    ),
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    text = ch.ifEmpty { "·" },
                                    fontSize = 22.sp,
                                    fontWeight = FontWeight.Bold,
                                    fontFamily = FontFamily.Monospace,
                                    color = if (ch.isNotEmpty()) c.textPrimary else c.textMuted
                                )
                            }
                            if (i == 2) Spacer(Modifier.width(6.dp))
                        }
                    }
                }
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(c.canvas)
                        .clickable(enabled = !isPairing, onClick = onDismiss)
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text("取消", style = t.body, color = c.textSecondary)
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (ready) c.accent else c.canvas)
                        .clickable(enabled = ready) { onConfirm(codeInput) }
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        if (isPairing) "连接中..." else "确认配对",
                        style = t.body,
                        fontWeight = FontWeight.SemiBold,
                        color = if (ready) Color.White else c.textMuted
                    )
                }
            }
        }
    }
}

// MARK: - 4. Storage Sub-Page

@Composable
private fun StorageSubPage(
    storageLoaded: Boolean,
    totalBytes: Long,
    dbBytes: Long,
    blobsBytes: Long,
    blobCount: Int,
    orphanCount: Int,
    orphanBytes: Long,
    onRefresh: () -> Unit,
    onBack: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val scope = rememberCoroutineScope()

    var isCleaning by remember { mutableStateOf(false) }
    var cleanupMsg by remember { mutableStateOf("") }
    var backups by remember { mutableStateOf<List<WhimBackupInfo>>(emptyList()) }
    var isBackingUp by remember { mutableStateOf(false) }
    var backupMsg by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        backups = runCatching { WhimCoreBridge.listBackups() }.getOrDefault(emptyList())
    }

    Column(modifier = Modifier.fillMaxSize()) {
        SettingsTopBar(
            title = "存储与清理",
            onBack = onBack,
            trailing = {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .clickable(onClick = onRefresh)
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(Icons.Rounded.Refresh, contentDescription = "刷新", tint = c.tagText, modifier = Modifier.size(16.dp))
                    Text("刷新", style = t.meta, fontWeight = FontWeight.Medium, color = c.tagText)
                }
            }
        )

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(c.card)
                    .border(0.8.dp, c.border, RoundedCornerShape(16.dp))
                    .padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.Bottom
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("本地总占用", style = t.meta, color = c.textSecondary)
                        Text(
                            if (storageLoaded) formatStorageBytes(totalBytes) else "--",
                            fontSize = 28.sp,
                            fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace,
                            color = c.textPrimary
                        )
                    }
                    Text("SQLite + 附件", style = t.meta, color = c.textMuted)
                }

                // Horizontal Segmented Bar
                if (storageLoaded) {
                    val safeTotal = totalBytes.coerceAtLeast(1L).toFloat()
                    val activeBlobBytes = (blobsBytes - orphanBytes).coerceAtLeast(0L)
                    val dbWeight = (dbBytes / safeTotal).coerceIn(0f, 1f)
                    val blobWeight = (activeBlobBytes / safeTotal).coerceIn(0f, 1f - dbWeight)
                    val orphanWeight = (orphanBytes / safeTotal).coerceIn(0f, 1f - dbWeight - blobWeight)
                    val restWeight = (1f - dbWeight - blobWeight - orphanWeight).coerceAtLeast(0f)

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(10.dp)
                            .clip(RoundedCornerShape(5.dp))
                            .background(c.canvas),
                        horizontalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        if (dbWeight > 0.005f) {
                            Box(Modifier.weight(dbWeight.coerceAtLeast(0.03f)).fillMaxHeight().background(c.accent))
                        }
                        if (blobWeight > 0.005f) {
                            Box(Modifier.weight(blobWeight.coerceAtLeast(0.03f)).fillMaxHeight().background(c.tagText))
                        }
                        if (orphanWeight > 0.005f) {
                            Box(Modifier.weight(orphanWeight.coerceAtLeast(0.03f)).fillMaxHeight().background(Color(0xFFE5A03D)))
                        }
                        if (restWeight > 0.005f) {
                            Spacer(Modifier.weight(restWeight))
                        }
                    }

                    // Breakdown rows
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        StorageBreakdownRow(c.accent, "笔记数据库", formatStorageBytes(dbBytes))
                        StorageBreakdownRow(c.tagText, "图片附件（$blobCount 张）", formatStorageBytes(activeBlobBytes))
                        StorageBreakdownRow(
                            Color(0xFFE5A03D),
                            "未引用冗余图片（$orphanCount 张）",
                            formatStorageBytes(orphanBytes)
                        )
                    }
                }
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(if (orphanCount > 0 && !isCleaning) c.accent else c.card)
                    .border(0.8.dp, if (orphanCount > 0) c.accent else c.border, RoundedCornerShape(12.dp))
                    .clickable(enabled = !isCleaning) {
                        isCleaning = true
                        cleanupMsg = ""
                        scope.launch {
                            val res = runCatching { WhimCoreBridge.cleanupOrphanBlobs(minAgeSec = 0, dryRun = false) }.getOrNull()
                            isCleaning = false
                            cleanupMsg = when {
                                res == null -> "清理失败，请重试"
                                res.removedFiles > 0 -> "已清理 ${res.removedFiles} 张冗余图片，释放 ${formatStorageBytes(res.freedBytes)}"
                                else -> "没有发现未引用的冗余图片，已整理数据库缓存"
                            }
                            onRefresh()
                        }
                    }
                    .padding(vertical = 13.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    if (isCleaning) "正在清理..." else "清理冗余图片与缓存",
                    style = t.body,
                    fontWeight = FontWeight.SemiBold,
                    color = if (orphanCount > 0 && !isCleaning) Color.White else c.textPrimary
                )
            }

            if (cleanupMsg.isNotEmpty()) {
                Text(cleanupMsg, style = t.meta, color = c.accent, modifier = Modifier.padding(horizontal = 4.dp))
            }

            // Daily Local Backup Card
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(c.card)
                    .border(0.8.dp, c.border, RoundedCornerShape(16.dp))
                    .padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("每日自动备份", style = t.section, color = c.textPrimary)
                        Text("每天启动时自动创建 SQLite 快照，滚动保留 7 天", style = t.meta, color = c.textSecondary)
                    }
                    Text(
                        "${backups.size} 份",
                        style = t.meta,
                        fontFamily = FontFamily.Monospace,
                        color = c.accent,
                        fontWeight = FontWeight.SemiBold
                    )
                }
                backups.firstOrNull()?.let { latest ->
                    Text(
                        "最近备份：${latest.name}（${formatStorageBytes(latest.sizeBytes)}）",
                        style = t.meta,
                        fontFamily = FontFamily.Monospace,
                        color = c.textMuted
                    )
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(c.canvas)
                        .border(0.8.dp, c.border, RoundedCornerShape(10.dp))
                        .clickable(enabled = !isBackingUp) {
                            isBackingUp = true
                            backupMsg = ""
                            scope.launch {
                                val res = runCatching { WhimCoreBridge.backupDatabase(keepDays = 7, force = true) }.getOrNull()
                                backups = runCatching { WhimCoreBridge.listBackups() }.getOrDefault(emptyList())
                                isBackingUp = false
                                backupMsg = if (res != null) {
                                    "已创建备份快照（${formatStorageBytes(res.sizeBytes)}）"
                                } else {
                                    "备份失败，请重试"
                                }
                            }
                        }
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        if (isBackingUp) "正在备份..." else "立即备份数据库",
                        style = t.body,
                        fontWeight = FontWeight.Medium,
                        color = c.textPrimary
                    )
                }
                if (backupMsg.isNotEmpty()) {
                    Text(backupMsg, style = t.meta, color = c.accent)
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun StorageBreakdownRow(dotColor: Color, label: String, value: String) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(dotColor))
            Text(label, style = t.body, color = c.textSecondary)
        }
        Text(value, style = t.body, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Monospace, color = c.textPrimary)
    }
}

// MARK: - 5. About & Update Sub-Page

@Composable
private fun AboutSubPage(
    availableRelease: ReleaseInfo?,
    onReleaseChanged: (ReleaseInfo?) -> Unit,
    onUpdateBadgeDismissed: () -> Unit,
    onBack: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var updateStatus by remember(availableRelease) {
        mutableStateOf(
            if (availableRelease != null) "发现新版本 ${availableRelease.tagName}"
            else "当前版本 v${GitHubUpdater.CURRENT_VERSION}，点击检查 GitHub 最新版本"
        )
    }
    var checkingUpdate by remember { mutableStateOf(false) }
    var downloadingUpdate by remember { mutableStateOf(false) }
    var downloadProgress by remember { mutableStateOf(0f) }

    Column(modifier = Modifier.fillMaxSize()) {
        SettingsTopBar(title = "关于与更新", onBack = onBack)

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // Centered Brand Hero
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(60.dp)
                        .clip(RoundedCornerShape(16.dp))
                        .background(c.accent),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Rounded.AutoAwesome, contentDescription = null, tint = Color.White, modifier = Modifier.size(30.dp))
                }
                Text("Whim", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = c.textPrimary)
                Text("v${GitHubUpdater.CURRENT_VERSION} · 本地优先闪念笔记", style = t.meta, color = c.textSecondary)
            }

            // Update Card
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(c.card)
                    .border(0.8.dp, c.border, RoundedCornerShape(16.dp))
                    .padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text("软件更新", style = t.section, color = c.textPrimary)
                Text(
                    updateStatus,
                    style = t.meta,
                    color = if (availableRelease != null) c.accent else c.textSecondary
                )

                if (downloadingUpdate) {
                    LinearProgressIndicator(
                        progress = { downloadProgress },
                        modifier = Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(3.dp)),
                        color = c.accent,
                        trackColor = c.canvas
                    )
                }

                availableRelease?.body?.takeIf { it.isNotBlank() }?.let { notes ->
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(c.canvas)
                            .padding(12.dp)
                    ) {
                        Text(notes, style = t.meta, color = c.textPrimary)
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (availableRelease == null) c.accent else c.canvas)
                            .clickable(enabled = !checkingUpdate && !downloadingUpdate) {
                                checkingUpdate = true
                                updateStatus = "正在检查 GitHub Release..."
                                GitHubUpdater.clearSkippedVersion(context)
                                scope.launch {
                                    val res = GitHubUpdater.checkLatest()
                                    checkingUpdate = false
                                    updateStatus = res.message
                                    onReleaseChanged(if (res.hasUpdate) res.release else null)
                                    if (!res.hasUpdate) onUpdateBadgeDismissed()
                                }
                            }
                            .padding(vertical = 11.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            if (checkingUpdate) "检查中..." else "检查更新",
                            style = t.body,
                            fontWeight = FontWeight.Medium,
                            color = if (availableRelease == null) Color.White else c.textPrimary
                        )
                    }

                    availableRelease?.let { rel ->
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(10.dp))
                                .background(c.accent)
                                .clickable(enabled = !downloadingUpdate) {
                                    downloadingUpdate = true
                                    downloadProgress = 0f
                                    updateStatus = "正在下载 APK..."
                                    scope.launch {
                                        updateStatus = GitHubUpdater.downloadAndInstallApk(context, rel) { p ->
                                            downloadProgress = p
                                            updateStatus = "正在下载 APK（${(p * 100).toInt()}%）..."
                                        }
                                        downloadingUpdate = false
                                    }
                                }
                                .padding(vertical = 11.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                if (downloadingUpdate) "下载中..." else "一键下载安装",
                                style = t.body,
                                fontWeight = FontWeight.SemiBold,
                                color = Color.White
                            )
                        }
                    }
                }

                if (availableRelease != null && !downloadingUpdate) {
                    Text(
                        "跳过此版本提醒",
                        style = t.meta,
                        color = c.textMuted,
                        modifier = Modifier
                            .align(Alignment.CenterHorizontally)
                            .clip(RoundedCornerShape(6.dp))
                            .clickable {
                                GitHubUpdater.skipVersion(context, availableRelease.tagName)
                                onReleaseChanged(null)
                                updateStatus = "已跳过 ${availableRelease.tagName} 提醒，可随时手动检查更新"
                                onUpdateBadgeDismissed()
                            }
                            .padding(horizontal = 10.dp, vertical = 4.dp)
                    )
                }
            }
        }
    }
}

// MARK: - Storage Helpers

private data class AndroidStorageUsage(
    val totalBytes: Long,
    val dbBytes: Long,
    val blobsBytes: Long,
    val blobCount: Int
)

private fun computeAndroidStorageUsage(rootDir: File): AndroidStorageUsage {
    if (!rootDir.exists()) return AndroidStorageUsage(0L, 0L, 0L, 0)
    var total = 0L
    var db = 0L
    var blobs = 0L
    var blobCnt = 0
    val blobsDirPath = File(rootDir, "blobs").absolutePath
    rootDir.walkTopDown().forEach { f ->
        if (f.isFile) {
            val len = f.length()
            total += len
            if (f.absolutePath.startsWith(blobsDirPath)) {
                blobs += len
                blobCnt++
            } else if (f.name.startsWith("whim.sqlite3")) {
                db += len
            }
        }
    }
    return AndroidStorageUsage(total, db, blobs, blobCnt)
}

private fun formatStorageBytes(bytes: Long): String {
    if (bytes < 1024L) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024.0) return String.format(Locale.getDefault(), "%.1f KB", kb)
    val mb = kb / 1024.0
    if (mb < 1024.0) return String.format(Locale.getDefault(), "%.1f MB", mb)
    val gb = mb / 1024.0
    return String.format(Locale.getDefault(), "%.2f GB", gb)
}
