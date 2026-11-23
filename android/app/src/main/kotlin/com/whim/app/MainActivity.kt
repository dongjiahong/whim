package com.whim.app

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Menu
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Text
import androidx.compose.material3.rememberDrawerState
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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.whim.app.capture.QuickCaptureActivity
import com.whim.app.capture.WhimWidgetProvider
import com.whim.app.core.WhimCoreBridge
import com.whim.app.core.WhimListFilter
import com.whim.app.core.WhimNote
import com.whim.app.core.WhimTagNode
import com.whim.app.sync.SyncWorker
import com.whim.app.ui.theme.WhimTheme
import com.whim.app.ui.theme.WhimThemeProvider
import com.whim.app.ui.theme.heatmapColor
import com.whim.app.update.GitHubUpdater
import com.whim.app.update.ReleaseInfo
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

private sealed class MobileTab {
    data object All : MobileTab()
    data object Review : MobileTab()
    data object Random : MobileTab()
    data class Tag(val path: String) : MobileTab()
}

class MainActivity : ComponentActivity() {
    companion object {
        const val EXTRA_OPEN_REVIEW = "open_review"
    }

    private val notifPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        WhimCoreBridge.ensureInit(this)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notifPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        val initialReview = intent?.getBooleanExtra(EXTRA_OPEN_REVIEW, false) == true

        setContent {
            val prefs = remember { getSharedPreferences("whim_ui_prefs", Context.MODE_PRIVATE) }
            var themeMode by remember { mutableStateOf(prefs.getString("theme_mode", "system") ?: "system") }
            val sysDark = androidx.compose.foundation.isSystemInDarkTheme()
            val useDark = when (themeMode) {
                "light" -> false
                "dark" -> true
                else -> sysDark
            }
            WhimThemeProvider(darkTheme = useDark) {
                FlomoMobileApp(
                    initialReviewMode = initialReview,
                    themeMode = themeMode,
                    onThemeModeChange = { next ->
                        themeMode = next
                        prefs.edit().putString("theme_mode", next).apply()
                    },
                    onOpenQuickCapture = {
                        startActivity(Intent(this, QuickCaptureActivity::class.java))
                    }
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // Mirror Navigator: phone does NOT run a server; it connects to Mac(s) via UDP discovery
        SyncWorker.enqueueImmediate(this)
    }
}

@Composable
private fun FlomoMobileApp(
    initialReviewMode: Boolean,
    themeMode: String,
    onThemeModeChange: (String) -> Unit,
    onOpenQuickCapture: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val drawerState = rememberDrawerState(DrawerValue.Closed)

    var activeTab by remember { mutableStateOf<MobileTab>(if (initialReviewMode) MobileTab.Review else MobileTab.All) }
    var searchQuery by remember { mutableStateOf("") }
    var showSearch by remember { mutableStateOf(false) }
    var showSyncCard by remember { mutableStateOf(false) }
    var showAboutCard by remember { mutableStateOf(false) }
    var updateStatus by remember { mutableStateOf("当前版本 v${GitHubUpdater.CURRENT_VERSION}，点击检查 GitHub 最新版本") }
    var availableRelease by remember { mutableStateOf<ReleaseInfo?>(null) }
    var checkingUpdate by remember { mutableStateOf(false) }
    var randomSeed by remember { mutableStateOf(0) }

    var allNotes by remember { mutableStateOf<List<WhimNote>>(emptyList()) }
    var displayedNotes by remember { mutableStateOf<List<WhimNote>>(emptyList()) }
    var tagTree by remember { mutableStateOf<List<WhimTagNode>>(emptyList()) }
    var pairCode by remember { mutableStateOf("") }
    var syncStatus by remember { mutableStateOf("") }
    var remoteCodeInput by remember { mutableStateOf("") }
    var manualAddrInput by remember { mutableStateOf("") }
    var peerStatuses by remember { mutableStateOf<List<com.whim.app.core.WhimPeerSyncStatus>>(emptyList()) }

    val dayFmt = remember { SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()) }

    val dailyCounts = remember(allNotes) {
        val map = mutableMapOf<String, Int>()
        for (n in allNotes) {
            if (n.createdAt > 0) {
                val key = dayFmt.format(Date(n.createdAt))
                map[key] = (map[key] ?: 0) + 1
            }
        }
        map
    }
    val uniqueTagCount = remember(allNotes) { allNotes.flatMap { it.tags }.toSet().size }
    val activeDayCount = remember(allNotes) {
        val earliest = allNotes.minOfOrNull { it.createdAt } ?: System.currentTimeMillis()
        val diffDays = ((System.currentTimeMillis() - earliest) / (24L * 3600L * 1000L)).toInt() + 1
        diffDays.coerceAtLeast(1)
    }

    fun reload() {
        scope.launch {
            runCatching {
                val full = WhimCoreBridge.listNotes(WhimListFilter(limit = 500))
                allNotes = full
                tagTree = WhimCoreBridge.listTagTree()
                pairCode = WhimCoreBridge.getPairCode()
                if (remoteCodeInput.isEmpty() && pairCode.isNotEmpty()) {
                    remoteCodeInput = pairCode
                }

                displayedNotes = when (val tab = activeTab) {
                    MobileTab.All -> if (searchQuery.isEmpty()) full else WhimCoreBridge.listNotes(WhimListFilter(query = searchQuery))
                    MobileTab.Review -> {
                        val today = WhimCoreBridge.listTodayNotes()
                        if (searchQuery.isEmpty()) today else today.filter { it.content.contains(searchQuery, ignoreCase = true) }
                    }
                    MobileTab.Random -> full.shuffled().take(12)
                    is MobileTab.Tag -> WhimCoreBridge.listNotes(WhimListFilter(query = searchQuery, tagPrefix = tab.path))
                }
            }
        }
    }

    LaunchedEffect(activeTab, searchQuery, randomSeed) {
        reload()
    }

    // Real-time SSE push loop: wakes up in < 50ms when Mac creates/edits/deletes a note,
    // with a 25s fallback sync in case of Wi-Fi hiccups.
    LaunchedEffect(Unit) {
        while (isActive) {
            val code = runCatching { WhimCoreBridge.getPairCode() }.getOrDefault("")
            if (code.length == 6) {
                val res = runCatching { WhimCoreBridge.syncOnce(timeoutSec = 3) }.getOrNull()
                if (res != null) {
                    peerStatuses = res.peers
                    if (res.notesMerged > 0 || res.blobsDownloaded > 0) {
                        reload()
                        WhimWidgetProvider.refreshAll(context)
                    }
                }
                // Block on SSE push stream until Mac broadcasts `event: changed` (or 25s keepalive fallback)
                WhimCoreBridge.waitForChange(timeoutSec = 25)
            } else {
                delay(2000L)
            }
        }
    }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            ModalDrawerSheet(
                drawerContainerColor = c.sidebar,
                modifier = Modifier.width(292.dp)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxHeight()
                        .verticalScroll(rememberScrollState())
                        .statusBarsPadding()
                        .padding(horizontal = 18.dp, vertical = 14.dp)
                ) {
                    // Header: Whim + LOCAL pill
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Whim", style = t.title, color = c.textPrimary)
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(4.dp))
                                .background(c.border)
                                .padding(horizontal = 5.dp, vertical = 2.dp)
                        ) {
                            Text("LOCAL", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = c.textPrimary)
                        }
                    }

                    Spacer(Modifier.height(16.dp))

                    // 3-Column Stats (笔记 / 标签 / 天)
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        StatBlock("${allNotes.size}", "笔记")
                        StatBlock("$uniqueTagCount", "标签")
                        StatBlock("$activeDayCount", "天")
                        Spacer(Modifier.width(12.dp))
                    }

                    Spacer(Modifier.height(14.dp))

                    // 12-week Activity Heatmap
                    MobileHeatmap(dailyCounts = dailyCounts)

                    Spacer(Modifier.height(16.dp))

                    // Primary Flomo Navigation Pills
                    DrawerNavRow(Icons.Rounded.GridView, "全部笔记", activeTab == MobileTab.All) {
                        activeTab = MobileTab.All
                        scope.launch { drawerState.close() }
                    }
                    DrawerNavRow(Icons.Rounded.AutoAwesome, "每日回顾", activeTab == MobileTab.Review) {
                        activeTab = MobileTab.Review
                        scope.launch { drawerState.close() }
                    }
                    DrawerNavRow(Icons.Rounded.Shuffle, "随机漫步", activeTab == MobileTab.Random) {
                        activeTab = MobileTab.Random
                        scope.launch { drawerState.close() }
                    }
                    DrawerNavRow(Icons.Rounded.Sync, "连到 Mac · ${if (pairCode.length == 6) "已配对" else "未配对"}", false) {
                        showSyncCard = true
                        showAboutCard = false
                        scope.launch { drawerState.close() }
                    }
                    DrawerNavRow(Icons.Rounded.AutoAwesome, "关于与更新 · v${GitHubUpdater.CURRENT_VERSION}", false) {
                        showAboutCard = true
                        showSyncCard = false
                        scope.launch { drawerState.close() }
                    }

                    Spacer(Modifier.height(16.dp))
                    Text("全部标签", style = t.meta, color = c.textMuted, modifier = Modifier.padding(start = 6.dp, bottom = 6.dp))

                    if (tagTree.isEmpty()) {
                        Text("输入 #工作/架构 自动生成标签树", style = t.meta, color = c.textMuted, modifier = Modifier.padding(start = 6.dp))
                    } else {
                        DrawerTagTree(
                            nodes = tagTree,
                            depth = 0,
                            activeTab = activeTab,
                            onSelect = { path ->
                                activeTab = MobileTab.Tag(path)
                                scope.launch { drawerState.close() }
                            }
                        )
                    }
                }
            }
        }
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(c.canvas)
                .statusBarsPadding()
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                // Top Header Bar
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Icon(
                            Icons.Rounded.Menu,
                            contentDescription = "菜单",
                            tint = c.textPrimary,
                            modifier = Modifier
                                .size(24.dp)
                                .clickable { scope.launch { drawerState.open() } }
                        )
                        Text(
                            text = when (val tab = activeTab) {
                                MobileTab.All -> "全部笔记"
                                MobileTab.Review -> "每日回顾"
                                MobileTab.Random -> "随机漫步"
                                is MobileTab.Tag -> "#${tab.path}"
                            },
                            style = t.title,
                            color = c.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Rounded.Search,
                            contentDescription = "搜索",
                            tint = c.textSecondary,
                            modifier = Modifier
                                .size(22.dp)
                                .clickable { showSearch = !showSearch }
                        )
                        Icon(
                            Icons.Rounded.Sync,
                            contentDescription = "同步",
                            tint = c.textSecondary,
                            modifier = Modifier
                                .size(22.dp)
                                .clickable {
                                    showSyncCard = !showSyncCard
                                    scope.launch {
                                        syncStatus = "正在通过 UDP 发现并同步..."
                                        val res = WhimCoreBridge.syncOnce()
                                        peerStatuses = res.peers
                                        syncStatus = when {
                                            res.peersSynced > 0 -> "已同步 ${res.peersSynced} 台设备" + if (res.notesMerged > 0) " · 合并 ${res.notesMerged} 条" else ""
                                            res.peers.isNotEmpty() -> res.peers.first().message
                                            else -> "暂未发现同 Wi-Fi 下的其他 Whim 设备"
                                        }
                                        reload()
                                        WhimWidgetProvider.refreshAll(context)
                                    }
                                }
                        )
                    }
                }

                if (showSearch) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(c.searchBg)
                            .padding(horizontal = 12.dp, vertical = 9.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Rounded.Search, contentDescription = null, tint = c.textMuted, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(8.dp))
                        BasicTextField(
                            value = searchQuery,
                            onValueChange = { searchQuery = it },
                            singleLine = true,
                            textStyle = t.body.copy(color = c.textPrimary),
                            cursorBrush = SolidColor(c.accent),
                            modifier = Modifier.fillMaxWidth(),
                            decorationBox = { inner ->
                                if (searchQuery.isEmpty()) Text("搜索笔记或 #标签...", style = t.body, color = c.textMuted)
                                inner()
                            }
                        )
                    }
                }

                if (showSyncCard) {
                    // Mirror Navigator PhoneHome LinkSheet: phone does NOT generate a code; it enters Mac's 6-digit code.
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 6.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(c.card)
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                            Text("连到 Mac", style = t.section, color = c.textPrimary)
                            Text(
                                "刷新",
                                style = t.meta,
                                color = c.tagText,
                                modifier = Modifier.clickable {
                                    scope.launch {
                                        syncStatus = "正在查找同 Wi-Fi 下的 Mac..."
                                        val res = WhimCoreBridge.syncOnce()
                                        peerStatuses = res.peers
                                        syncStatus = when {
                                            res.peersSynced > 0 -> "已同步 ${res.peersSynced} 台 Mac" + if (res.notesMerged > 0) " · 合并 ${res.notesMerged} 条" else ""
                                            res.peers.isNotEmpty() -> res.peers.first().message
                                            else -> "暂未发现同 Wi-Fi 下的 Mac"
                                        }
                                        reload()
                                    }
                                }
                            )
                        }
                        Text(
                            text = "在 Mac 的「设置 → 局域网同步」里找到 6 位数字。同一个 Wi-Fi 下会自动找到每一台 Mac，只要对一次。",
                            style = t.meta,
                            color = c.textSecondary
                        )

                        Box(modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(c.canvas).padding(horizontal = 12.dp, vertical = 12.dp)) {
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
                            Text("设备", style = t.meta, color = c.textMuted)
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
                                .background(if (codeReady) c.accent else c.canvas)
                                .clickable(enabled = codeReady) {
                                    val digits = remoteCodeInput.filter { it.isDigit() }
                                    val addr = manualAddrInput.trim()
                                    scope.launch {
                                        if (addr.isNotEmpty()) {
                                            runCatching { WhimCoreBridge.setManualPeers(listOf(addr)) }
                                        }
                                        runCatching { WhimCoreBridge.setPairCode(digits) }
                                            .onSuccess { updated ->
                                                pairCode = updated
                                                syncStatus = "正在自动发现 Mac 并同步..."
                                                val res = WhimCoreBridge.syncOnce()
                                                peerStatuses = res.peers
                                                syncStatus = when {
                                                    res.peersSynced > 0 -> "已同步 ${res.peersSynced} 台 Mac" + if (res.notesMerged > 0) " · 合并 ${res.notesMerged} 条" else ""
                                                    res.peers.isNotEmpty() -> res.peers.first().message
                                                    else -> "已保存配对码，未发现同一 Wi-Fi 下的 Mac"
                                                }
                                                reload()
                                                WhimWidgetProvider.refreshAll(context)
                                            }
                                            .onFailure { syncStatus = it.message ?: "配对码无效" }
                                    }
                                }
                                .padding(vertical = 12.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text("配对", style = t.body, color = if (codeReady) Color.White else c.textMuted, fontWeight = FontWeight.SemiBold)
                        }

                        Text("找不到 Mac 时，才把 Mac 的地址填进来（可选）", style = t.meta, color = c.textMuted)
                        Box(modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(c.canvas).padding(horizontal = 12.dp, vertical = 9.dp)) {
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
                }

                if (showAboutCard) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 6.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(c.card)
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text("设置与关于 · v${GitHubUpdater.CURRENT_VERSION}", style = t.section, color = c.textPrimary)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            listOf("system" to "跟随系统", "light" to "浅色", "dark" to "深色").forEach { (key, label) ->
                                val active = themeMode == key
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(7.dp))
                                        .background(if (active) c.accent else c.canvas)
                                        .clickable { onThemeModeChange(key) }
                                        .padding(horizontal = 12.dp, vertical = 6.dp)
                                ) {
                                    Text(label, style = t.meta, color = if (active) Color.White else c.textPrimary)
                                }
                            }
                        }
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
                }

                if (activeTab == MobileTab.Random) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(c.card)
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("随机重温历史闪念", style = t.meta, color = c.textSecondary)
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(7.dp))
                                .background(c.accent)
                                .clickable { randomSeed++ }
                                .padding(horizontal = 12.dp, vertical = 6.dp)
                        ) {
                            Text("换一批", style = t.meta, color = Color.White, fontWeight = FontWeight.Medium)
                        }
                    }
                }

                // Flomo Note Card Feed
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 96.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    if (displayedNotes.isEmpty()) {
                        item {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(top = 80.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Text("暂无笔记，点击右下角记下第一个想法", style = t.body, color = c.textMuted)
                            }
                        }
                    } else {
                        items(displayedNotes, key = { it.id }) { note ->
                            FlomoMobileNoteCard(
                                note = note,
                                onTapTag = { path -> activeTab = MobileTab.Tag(path) },
                                onTogglePin = {
                                    scope.launch {
                                        WhimCoreBridge.updateNote(note.id, pinned = !note.pinned)
                                        reload()
                                        runCatching { WhimCoreBridge.syncOnce(timeoutSec = 3) }
                                        SyncWorker.enqueueImmediate(context)
                                    }
                                },
                                onCopy = {
                                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                    cm.setPrimaryClip(ClipData.newPlainText("whim", note.content))
                                },
                                onDelete = {
                                    scope.launch {
                                        WhimCoreBridge.updateNote(note.id, deleted = true)
                                        reload()
                                        runCatching { WhimCoreBridge.syncOnce(timeoutSec = 3) }
                                        SyncWorker.enqueueImmediate(context)
                                    }
                                }
                            )
                        }
                    }
                }
            }

            // Sage-green floating capture button (flomo mobile style)
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 20.dp, bottom = 28.dp)
                    .size(54.dp)
                    .clip(CircleShape)
                    .background(c.accent)
                    .clickable(onClick = onOpenQuickCapture),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Rounded.Add, contentDescription = "新建笔记", tint = Color.White, modifier = Modifier.size(26.dp))
            }
        }
    }
}

@Composable
private fun StatBlock(value: String, label: String) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    Column {
        Text(value, style = t.statNumber, color = c.textPrimary)
        Text(label, style = t.meta, color = c.textMuted)
    }
}

@Composable
private fun MobileHeatmap(dailyCounts: Map<String, Int>) {
    val c = WhimTheme.colors
    val dayFmt = remember { SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()) }
    val todayKey = remember { dayFmt.format(Date()) }
    val cols = 12
    val rows = 7
    val dates = remember {
        val cal = Calendar.getInstance()
        cal.add(Calendar.DAY_OF_YEAR, -(cols * rows - 1))
        List(cols) {
            List(rows) {
                val k = dayFmt.format(cal.time)
                cal.add(Calendar.DAY_OF_YEAR, 1)
                k
            }
        }
    }

    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        dates.forEach { col ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                col.forEach { key ->
                    val cnt = dailyCounts[key] ?: 0
                    val isToday = key == todayKey
                    Box(
                        modifier = Modifier
                            .size(14.dp)
                            .clip(RoundedCornerShape(3.dp))
                            .background(c.heatmapColor(cnt))
                            .then(
                                if (isToday) Modifier.border(1.dp, c.textSecondary, RoundedCornerShape(3.dp))
                                else Modifier
                            )
                    )
                }
            }
        }
    }
}

@Composable
private fun DrawerNavRow(icon: ImageVector, title: String, active: Boolean, onClick: () -> Unit) {
    val c = WhimTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (active) c.accent else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(icon, contentDescription = null, tint = if (active) Color.White else c.textSecondary, modifier = Modifier.size(18.dp))
        Text(
            text = title,
            fontSize = 14.sp,
            fontWeight = if (active) FontWeight.Medium else FontWeight.Normal,
            color = if (active) Color.White else c.textPrimary
        )
    }
}

@Composable
private fun DrawerTagTree(
    nodes: List<WhimTagNode>,
    depth: Int,
    activeTab: MobileTab,
    onSelect: (String) -> Unit
) {
    val c = WhimTheme.colors
    Column {
        for (node in nodes) {
            val selected = activeTab is MobileTab.Tag && activeTab.path == node.fullPath
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(7.dp))
                    .background(if (selected) c.accent else Color.Transparent)
                    .clickable { onSelect(node.fullPath) }
                    .padding(start = (depth * 14 + 10).dp, end = 10.dp, top = 7.dp, bottom = 7.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("#", fontSize = 14.sp, color = if (selected) Color.White else c.textMuted)
                    Text(node.name, fontSize = 14.sp, color = if (selected) Color.White else c.textPrimary)
                }
                Text("${node.count}", fontSize = 12.sp, color = if (selected) Color.White.copy(alpha = 0.8f) else c.textMuted)
            }
            if (node.children.isNotEmpty()) {
                DrawerTagTree(node.children, depth + 1, activeTab, onSelect)
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FlomoMobileNoteCard(
    note: WhimNote,
    onTapTag: (String) -> Unit,
    onTogglePin: () -> Unit,
    onCopy: () -> Unit,
    onDelete: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    var menuExpanded by remember { mutableStateOf(false) }
    var textExpanded by remember { mutableStateOf(false) }
    val isLong = note.content.length > 220 || note.content.lines().size > 6

    val timeStr = remember(note.createdAt) {
        SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date(note.createdAt))
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(c.card)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp)
    ) {
        // Header: 置顶 · YYYY-MM-DD HH:mm + ···
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = if (note.pinned) "置顶 · $timeStr" else timeStr,
                style = t.meta,
                color = c.textSecondary
            )
            Box {
                Icon(
                    Icons.Rounded.MoreHoriz,
                    contentDescription = "更多",
                    tint = c.textMuted,
                    modifier = Modifier
                        .size(20.dp)
                        .clickable { menuExpanded = true }
                )
                DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                    DropdownMenuItem(
                        text = { Text(if (note.pinned) "取消置顶" else "置顶") },
                        onClick = { menuExpanded = false; onTogglePin() }
                    )
                    DropdownMenuItem(
                        text = { Text("复制内容") },
                        onClick = { menuExpanded = false; onCopy() }
                    )
                    DropdownMenuItem(
                        text = { Text("删除") },
                        onClick = { menuExpanded = false; onDelete() }
                    )
                }
            }
        }

        // Cool blue tag pills right below timestamp
        if (note.tags.isNotEmpty()) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                note.tags.forEach { tag ->
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(5.dp))
                            .background(c.tagBg)
                            .clickable { onTapTag(tag) }
                            .padding(horizontal = 8.dp, vertical = 3.dp)
                    ) {
                        Text(text = "#$tag", style = t.meta, color = c.tagText)
                    }
                }
            }
        }

        // Interleaved inline Text + Image blocks (strip #tags already shown as top pills)
        val displayBody = remember(note.content, note.tags) {
            var cleaned = note.content
            for (tag in note.tags.sortedByDescending { it.length }) {
                val escaped = Regex.escape(tag).replace("/", "\\s*/\\s*")
                cleaned = Regex("#\\s*$escaped(?=$|[\\s,.;:!?，。；：！？\\)\\]）】」』])").replace(cleaned, "")
            }
            cleaned.lines().map { it.trim() }.filterIndexed { i, line ->
                line.isNotEmpty() || (i > 0)
            }.joinToString("\n").trim()
        }
        val blobRegex = remember { Regex("!\\[[^\\]]*\\]\\(whim://blob/([a-fA-F0-9]{64})\\)") }
        val pathByHash = remember(note.attachments) { note.attachments.associate { it.sha256 to it.localPath } }
        val matches = remember(displayBody) { blobRegex.findAll(displayBody).toList() }
        var cursor = 0
        val referenced = mutableSetOf<String>()

        matches.forEach { m ->
            if (m.range.first > cursor) {
                val seg = displayBody.substring(cursor, m.range.first).trim()
                if (seg.isNotEmpty()) {
                    Text(
                        text = seg,
                        style = t.body,
                        color = c.textPrimary,
                        maxLines = if (textExpanded || !isLong) Int.MAX_VALUE else 6,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            val hash = m.groupValues[1]
            referenced.add(hash)
            val path = pathByHash[hash].orEmpty()
            if (path.isNotEmpty()) {
                AsyncImage(
                    model = File(path),
                    contentDescription = "内联图片",
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(180.dp)
                        .clip(RoundedCornerShape(8.dp))
                )
            }
            cursor = m.range.last + 1
        }
        if (cursor < displayBody.length) {
            val tail = displayBody.substring(cursor).trim()
            if (tail.isNotEmpty()) {
                Text(
                    text = tail,
                    style = t.body,
                    color = c.textPrimary,
                    maxLines = if (textExpanded || !isLong) Int.MAX_VALUE else 6,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }

        if (isLong) {
            Text(
                text = if (textExpanded) "收起" else "展开",
                style = t.meta,
                color = c.tagText,
                modifier = Modifier.clickable { textExpanded = !textExpanded }
            )
        }

        // Legacy fallback for any attachment not inline-referenced
        val trailing = note.attachments.filter { it.sha256 !in referenced && it.localPath.isNotEmpty() }
        if (trailing.isNotEmpty()) {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(trailing) { att ->
                    AsyncImage(
                        model = File(att.localPath),
                        contentDescription = "图片附件",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(104.dp)
                            .clip(RoundedCornerShape(8.dp))
                    )
                }
            }
        }
    }
}
