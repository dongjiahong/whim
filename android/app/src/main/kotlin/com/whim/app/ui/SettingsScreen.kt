package com.whim.app.ui

import android.app.TimePickerDialog
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Update
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.whim.app.capture.WhimWidgetProvider
import com.whim.app.core.WhimCoreBridge
import com.whim.app.core.WhimPeerSyncStatus
import com.whim.app.review.DailyReviewReceiver
import com.whim.app.review.DailyReviewScheduler
import com.whim.app.review.ReviewSchedule
import com.whim.app.ui.theme.WhimTheme
import com.whim.app.update.GitHubUpdater
import com.whim.app.update.ReleaseInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Calendar
import java.util.Locale

enum class SettingsFocusSection {
    ALL,
    REVIEW,
    SYNC,
    ABOUT
}

@Composable
fun MobileSettingsScreen(
    focusSection: SettingsFocusSection = SettingsFocusSection.ALL,
    themeMode: String,
    onThemeModeChange: (String) -> Unit,
    reviewSchedule: ReviewSchedule,
    onReviewScheduleChange: (ReviewSchedule) -> Unit,
    notifPermissionGranted: Boolean,
    exactAlarmGranted: Boolean,
    onRequestNotificationPermission: () -> Unit,
    pairCode: String,
    onPairCodeUpdated: (String) -> Unit,
    peerStatuses: List<WhimPeerSyncStatus>,
    onPeerStatusesUpdated: (List<WhimPeerSyncStatus>) -> Unit,
    onSyncCompleted: () -> Unit,
    onBack: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val scrollState = rememberScrollState()

    var remoteCodeInput by remember(pairCode) { mutableStateOf(pairCode) }
    var manualAddrInput by remember { mutableStateOf("") }
    var syncStatus by remember { mutableStateOf("") }
    var isSyncing by remember { mutableStateOf(false) }

    var reviewSettingsMsg by remember { mutableStateOf("") }
    var updateStatus by remember { mutableStateOf("当前版本 v${GitHubUpdater.CURRENT_VERSION}，点击检查 GitHub 最新版本") }
    var availableRelease by remember { mutableStateOf<ReleaseInfo?>(null) }
    var checkingUpdate by remember { mutableStateOf(false) }

    BackHandler(onBack = onBack)

    LaunchedEffect(focusSection) {
        when (focusSection) {
            SettingsFocusSection.REVIEW -> scrollState.animateScrollTo(140)
            SettingsFocusSection.SYNC -> scrollState.animateScrollTo(760)
            SettingsFocusSection.ABOUT -> scrollState.animateScrollTo(scrollState.maxValue)
            SettingsFocusSection.ALL -> Unit
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(c.canvas)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
    ) {
        // Top App Bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = onBack)
                    .padding(horizontal = 4.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp)
            ) {
                Icon(
                    Icons.Rounded.ChevronLeft,
                    contentDescription = "返回",
                    tint = c.textPrimary,
                    modifier = Modifier.size(24.dp)
                )
                Text("设置", style = t.title, color = c.textPrimary)
            }
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(scrollState)
                .padding(horizontal = 16.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            // 1. 外观主题
            SettingsSectionCard(
                icon = Icons.Rounded.Palette,
                title = "外观主题",
                highlighted = false
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("system" to "跟随系统", "light" to "浅色", "dark" to "深色").forEach { (key, label) ->
                        val active = themeMode == key
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(8.dp))
                                .background(if (active) c.accent else c.canvas)
                                .clickable { onThemeModeChange(key) }
                                .padding(vertical = 9.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                label,
                                style = t.meta,
                                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                                color = if (active) Color.White else c.textPrimary
                            )
                        }
                    }
                }
            }

            // 2. 每日复盘系统提醒
            val weekdayItems = listOf(
                Calendar.MONDAY to "一",
                Calendar.TUESDAY to "二",
                Calendar.WEDNESDAY to "三",
                Calendar.THURSDAY to "四",
                Calendar.FRIDAY to "五",
                Calendar.SATURDAY to "六",
                Calendar.SUNDAY to "日"
            )
            SettingsSectionCard(
                icon = Icons.Rounded.Notifications,
                title = "每日复盘系统提醒",
                highlighted = focusSection == SettingsFocusSection.REVIEW
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(
                        modifier = Modifier.weight(1f).padding(end = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        Text("开启系统定时提醒", style = t.body, color = c.textPrimary)
                        Text("杀进程与重启手机后依然通过 AlarmManager 准时触发", style = t.meta, color = c.textSecondary)
                    }
                    Switch(
                        checked = reviewSchedule.enabled,
                        onCheckedChange = { checked ->
                            val updated = DailyReviewScheduler.updateSchedule(
                                context,
                                enabled = checked,
                                hour = reviewSchedule.hour,
                                minute = reviewSchedule.minute,
                                weekdays = reviewSchedule.weekdays,
                                skipIfEmpty = reviewSchedule.skipIfEmpty
                            )
                            onReviewScheduleChange(updated)
                            reviewSettingsMsg = if (checked) "已开启：${DailyReviewScheduler.formatSummary(updated)}" else "已关闭每日复盘提醒"
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Color.White,
                            checkedTrackColor = c.accent
                        )
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("提醒时间", style = t.body, color = if (reviewSchedule.enabled) c.textPrimary else c.textMuted)
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(c.canvas)
                            .clickable(enabled = reviewSchedule.enabled) {
                                TimePickerDialog(
                                    context,
                                    { _, pickedHour, pickedMinute ->
                                        val updated = DailyReviewScheduler.updateSchedule(
                                            context,
                                            enabled = reviewSchedule.enabled,
                                            hour = pickedHour,
                                            minute = pickedMinute,
                                            weekdays = reviewSchedule.weekdays,
                                            skipIfEmpty = reviewSchedule.skipIfEmpty
                                        )
                                        onReviewScheduleChange(updated)
                                        reviewSettingsMsg = "提醒时间已更新：${DailyReviewScheduler.formatSummary(updated)}"
                                    },
                                    reviewSchedule.hour,
                                    reviewSchedule.minute,
                                    true
                                ).show()
                            }
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                    ) {
                        Text(
                            String.format(Locale.getDefault(), "%02d:%02d", reviewSchedule.hour, reviewSchedule.minute),
                            style = t.section,
                            color = if (reviewSchedule.enabled) c.accent else c.textMuted
                        )
                    }
                }

                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("重复星期", style = t.body, color = if (reviewSchedule.enabled) c.textPrimary else c.textMuted)
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            listOf(
                                "每天" to ReviewSchedule.ALL_WEEKDAYS,
                                "工作日" to ReviewSchedule.WORKDAYS,
                                "周末" to ReviewSchedule.WEEKENDS
                            ).forEach { (label, preset) ->
                                val active = reviewSchedule.weekdays == preset
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(6.dp))
                                        .background(if (active && reviewSchedule.enabled) c.accent else c.canvas)
                                        .clickable(enabled = reviewSchedule.enabled) {
                                            val updated = DailyReviewScheduler.updateSchedule(
                                                context,
                                                enabled = reviewSchedule.enabled,
                                                hour = reviewSchedule.hour,
                                                minute = reviewSchedule.minute,
                                                weekdays = preset,
                                                skipIfEmpty = reviewSchedule.skipIfEmpty
                                            )
                                            onReviewScheduleChange(updated)
                                            reviewSettingsMsg = "重复周期已更新：${DailyReviewScheduler.formatSummary(updated)}"
                                        }
                                        .padding(horizontal = 9.dp, vertical = 4.dp)
                                ) {
                                    Text(label, style = t.meta, color = if (active && reviewSchedule.enabled) Color.White else c.textSecondary)
                                }
                            }
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        weekdayItems.forEach { (dayConst, label) ->
                            val selected = dayConst in reviewSchedule.weekdays
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(7.dp))
                                    .background(if (selected && reviewSchedule.enabled) c.accent else c.canvas)
                                    .clickable(enabled = reviewSchedule.enabled) {
                                        val nextDays = if (selected) {
                                            if (reviewSchedule.weekdays.size > 1) reviewSchedule.weekdays - dayConst else reviewSchedule.weekdays
                                        } else {
                                            reviewSchedule.weekdays + dayConst
                                        }
                                        val updated = DailyReviewScheduler.updateSchedule(
                                            context,
                                            enabled = reviewSchedule.enabled,
                                            hour = reviewSchedule.hour,
                                            minute = reviewSchedule.minute,
                                            weekdays = nextDays,
                                            skipIfEmpty = reviewSchedule.skipIfEmpty
                                        )
                                        onReviewScheduleChange(updated)
                                        reviewSettingsMsg = "已更新：${DailyReviewScheduler.formatSummary(updated)}"
                                    }
                                    .padding(vertical = 8.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    label,
                                    style = t.meta,
                                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                                    color = if (selected && reviewSchedule.enabled) Color.White else c.textSecondary
                                )
                            }
                        }
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(
                        modifier = Modifier.weight(1f).padding(end = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        Text("今日无笔记时不打扰", style = t.body, color = if (reviewSchedule.enabled) c.textPrimary else c.textMuted)
                        Text("当天 0 条记录时静默跳过晚间通知", style = t.meta, color = c.textSecondary)
                    }
                    Switch(
                        checked = reviewSchedule.skipIfEmpty,
                        enabled = reviewSchedule.enabled,
                        onCheckedChange = { checked ->
                            val updated = DailyReviewScheduler.updateSchedule(
                                context,
                                enabled = reviewSchedule.enabled,
                                hour = reviewSchedule.hour,
                                minute = reviewSchedule.minute,
                                weekdays = reviewSchedule.weekdays,
                                skipIfEmpty = checked
                            )
                            onReviewScheduleChange(updated)
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Color.White,
                            checkedTrackColor = c.accent
                        )
                    )
                }

                if (!notifPermissionGranted || !exactAlarmGranted) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(c.canvas)
                            .padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        if (!notifPermissionGranted) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("未开启系统通知权限", style = t.meta, color = c.textSecondary)
                                Text(
                                    "去开启",
                                    style = t.meta,
                                    color = c.tagText,
                                    fontWeight = FontWeight.Medium,
                                    modifier = Modifier.clickable { onRequestNotificationPermission() }
                                )
                            }
                        }
                        if (!exactAlarmGranted && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("未授予精确闹钟权限（息屏可能延迟）", style = t.meta, color = c.textSecondary)
                                Text(
                                    "去授权",
                                    style = t.meta,
                                    color = c.tagText,
                                    fontWeight = FontWeight.Medium,
                                    modifier = Modifier.clickable {
                                        runCatching {
                                            val i = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                                                data = Uri.parse("package:${context.packageName}")
                                            }
                                            context.startActivity(i)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(7.dp))
                            .background(c.accent)
                            .clickable {
                                scope.launch {
                                    val cnt = withContext(Dispatchers.IO) {
                                        runCatching { WhimCoreBridge.countTodayNotesBlocking() }.getOrDefault(0)
                                    }
                                    val sent = DailyReviewReceiver.postNotification(context, cnt, isTest = true)
                                    reviewSettingsMsg = if (sent) {
                                        "测试通知已发送，可在通知栏点击「去复盘」或「30 分钟后再提醒」"
                                    } else {
                                        "未获得通知权限，请先允许 Whim 发送系统通知"
                                    }
                                }
                            }
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                    ) {
                        Text("发送测试通知", style = t.meta, color = Color.White, fontWeight = FontWeight.Medium)
                    }
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(7.dp))
                            .background(c.canvas)
                            .clickable {
                                runCatching {
                                    val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                        putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                                    }
                                    context.startActivity(i)
                                }
                            }
                            .padding(horizontal = 12.dp, vertical = 8.dp)
                    ) {
                        Text("系统通知设置", style = t.meta, color = c.textSecondary)
                    }
                }

                if (reviewSettingsMsg.isNotEmpty()) {
                    Text(reviewSettingsMsg, style = t.meta, color = c.accent)
                }
            }

            // 3. 局域网同步（连到 Mac）
            SettingsSectionCard(
                icon = Icons.Rounded.Sync,
                title = "局域网同步 · 连到 Mac",
                highlighted = focusSection == SettingsFocusSection.SYNC,
                trailing = {
                    Text(
                        if (isSyncing) "同步中..." else "立即刷新",
                        style = t.meta,
                        color = if (isSyncing) c.textMuted else c.tagText,
                        modifier = Modifier.clickable(enabled = !isSyncing) {
                            scope.launch {
                                isSyncing = true
                                syncStatus = "正在查找同 Wi-Fi 下的 Mac..."
                                val res = WhimCoreBridge.syncOnce()
                                isSyncing = false
                                onPeerStatusesUpdated(res.peers)
                                syncStatus = when {
                                    res.peersSynced > 0 -> "已同步 ${res.peersSynced} 台 Mac" + if (res.notesMerged > 0) " · 合并 ${res.notesMerged} 条" else ""
                                    res.peers.isNotEmpty() -> res.peers.first().message
                                    else -> "暂未发现同 Wi-Fi 下的 Mac"
                                }
                                onSyncCompleted()
                                WhimWidgetProvider.refreshAll(context)
                            }
                        }
                    )
                }
            ) {
                Text(
                    text = "在 Mac 的「设置 → 局域网同步」里找到 6 位数字。同一个 Wi-Fi 下会自动发现每一台 Mac，只要配对一次。",
                    style = t.meta,
                    color = c.textSecondary
                )

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(c.canvas)
                        .padding(horizontal = 12.dp, vertical = 12.dp)
                ) {
                    BasicTextField(
                        value = remoteCodeInput,
                        onValueChange = { remoteCodeInput = it.filter { ch -> ch.isDigit() }.take(6) },
                        singleLine = true,
                        textStyle = t.statNumber.copy(color = c.textPrimary),
                        cursorBrush = SolidColor(c.accent),
                        modifier = Modifier.fillMaxWidth(),
                        decorationBox = { inner ->
                            if (remoteCodeInput.isEmpty()) Text("482 913", style = t.statNumber, color = c.textMuted)
                            inner()
                        }
                    )
                }

                if (peerStatuses.isNotEmpty()) {
                    Text("已发现设备", style = t.meta, color = c.textMuted)
                    peerStatuses.forEach { peer ->
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                if (peer.displayName.isEmpty()) peer.addr else "${peer.displayName} · ${peer.addr}",
                                style = t.body,
                                color = c.textPrimary
                            )
                            Text(
                                peer.message,
                                style = t.meta,
                                color = if (peer.status == "synced") c.accent else Color(0xFFD05A5A)
                            )
                        }
                    }
                }

                if (syncStatus.isNotEmpty()) {
                    Text(syncStatus, style = t.meta, color = c.textSecondary)
                }

                val codeReady = remoteCodeInput.filter { it.isDigit() }.length == 6
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (codeReady && !isSyncing) c.accent else c.canvas)
                        .clickable(enabled = codeReady && !isSyncing) {
                            val digits = remoteCodeInput.filter { it.isDigit() }
                            val addr = manualAddrInput.trim()
                            scope.launch {
                                isSyncing = true
                                if (addr.isNotEmpty()) {
                                    runCatching { WhimCoreBridge.setManualPeers(listOf(addr)) }
                                }
                                runCatching { WhimCoreBridge.setPairCode(digits) }
                                    .onSuccess { updated ->
                                        onPairCodeUpdated(updated)
                                        syncStatus = "正在自动发现 Mac 并同步..."
                                        val res = WhimCoreBridge.syncOnce()
                                        onPeerStatusesUpdated(res.peers)
                                        syncStatus = when {
                                            res.peersSynced > 0 -> "已同步 ${res.peersSynced} 台 Mac" + if (res.notesMerged > 0) " · 合并 ${res.notesMerged} 条" else ""
                                            res.peers.isNotEmpty() -> res.peers.first().message
                                            else -> "已保存配对码，未发现同一 Wi-Fi 下的 Mac"
                                        }
                                        onSyncCompleted()
                                        WhimWidgetProvider.refreshAll(context)
                                    }
                                    .onFailure { syncStatus = it.message ?: "配对码无效" }
                                isSyncing = false
                            }
                        }
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        if (isSyncing) "同步中..." else "配对并同步",
                        style = t.body,
                        color = if (codeReady && !isSyncing) Color.White else c.textMuted,
                        fontWeight = FontWeight.SemiBold
                    )
                }

                Text("找不到 Mac 时，才把 Mac 的地址填进来（可选）", style = t.meta, color = c.textMuted)
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(c.canvas)
                        .padding(horizontal = 12.dp, vertical = 9.dp)
                ) {
                    BasicTextField(
                        value = manualAddrInput,
                        onValueChange = { manualAddrInput = it },
                        singleLine = true,
                        textStyle = t.body.copy(color = c.textPrimary),
                        cursorBrush = SolidColor(c.accent),
                        modifier = Modifier.fillMaxWidth(),
                        decorationBox = { inner ->
                            if (manualAddrInput.isEmpty()) Text("192.168.5.111:8788", style = t.meta, color = c.textMuted)
                            inner()
                        }
                    )
                }
            }

            // 4. 关于与更新
            SettingsSectionCard(
                icon = Icons.Rounded.Update,
                title = "关于与更新 · v${GitHubUpdater.CURRENT_VERSION}",
                highlighted = focusSection == SettingsFocusSection.ABOUT
            ) {
                Text(updateStatus, style = t.meta, color = c.textSecondary)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(7.dp))
                            .background(c.accent)
                            .clickable(enabled = !checkingUpdate) {
                                checkingUpdate = true
                                updateStatus = "正在检查 GitHub Release..."
                                scope.launch {
                                    val res = GitHubUpdater.checkLatest()
                                    checkingUpdate = false
                                    updateStatus = res.message
                                    availableRelease = if (res.hasUpdate) res.release else null
                                }
                            }
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                    ) {
                        Text(if (checkingUpdate) "检查中..." else "检查更新", style = t.meta, color = Color.White, fontWeight = FontWeight.Medium)
                    }
                    availableRelease?.let { rel ->
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(7.dp))
                                .background(c.tagBg)
                                .clickable {
                                    updateStatus = "正在下载 APK..."
                                    scope.launch {
                                        updateStatus = GitHubUpdater.downloadAndInstallApk(context, rel)
                                    }
                                }
                                .padding(horizontal = 14.dp, vertical = 8.dp)
                        ) {
                            Text("一键下载安装", style = t.meta, color = c.tagText, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun SettingsSectionCard(
    icon: ImageVector,
    title: String,
    highlighted: Boolean,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(c.card)
            .border(
                width = if (highlighted) 1.2.dp else 0.6.dp,
                color = if (highlighted) c.accent else c.border,
                shape = RoundedCornerShape(12.dp)
            )
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
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(icon, contentDescription = null, tint = c.accent, modifier = Modifier.size(18.dp))
                Text(title, style = t.section, color = c.textPrimary)
            }
            trailing?.invoke()
        }
        content()
    }
}
