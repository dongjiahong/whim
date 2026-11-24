package com.whim.app

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Bundle
import android.util.LruCache
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Archive
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.Menu
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import coil.compose.AsyncImage
import coil.imageLoader
import coil.request.ImageRequest
import coil.size.Precision
import com.whim.app.capture.QuickCaptureActivity
import com.whim.app.capture.WhimWidgetProvider
import com.whim.app.core.WhimAttachment
import com.whim.app.core.WhimCoreBridge
import com.whim.app.core.WhimListFilter
import com.whim.app.core.WhimNote
import com.whim.app.core.WhimNoteCursor
import com.whim.app.core.WhimStats
import com.whim.app.core.WhimSyncHealthStatus
import com.whim.app.core.WhimSyncPeer
import com.whim.app.core.WhimTagNode
import com.whim.app.review.DailyReviewReceiver
import com.whim.app.review.DailyReviewScheduler
import com.whim.app.sync.SyncWorker
import com.whim.app.ui.MobileSettingsScreen
import com.whim.app.ui.SettingsFocusSection
import com.whim.app.ui.theme.WhimTheme
import com.whim.app.ui.theme.WhimThemeProvider
import com.whim.app.ui.theme.heatmapColor
import com.whim.app.update.GitHubUpdater
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.abs

private sealed class MobileTab {
    data object All : MobileTab()
    data object Review : MobileTab()
    data object Random : MobileTab()
    data object Archived : MobileTab()
    data class Day(val dayStr: String) : MobileTab()
    data class Tag(val path: String) : MobileTab()
}

private val mobileTagStripRegex = Regex(
    "(^|[\\s(\\[{（【「『，。、；：！？,.;:!?])#([^\\s#,.;:!?，。、；：！？)\\]}）】」』]+)",
    RegexOption.MULTILINE
)
private val mobileBlobRegex = Regex("!\\[[^\\]]*\\]\\(whim://blob/([a-fA-F0-9]{64})\\)")
private val mobileOrderedListRegex = Regex("^(\\d+)\\. (.*)$")
private val inlineMdTokenRegex = Regex("(\\*\\*[^*]+\\*\\*|~~[^~]+~~|`[^`]+`|\\*[^*]+\\*)")

private fun dayRangeMs(dayOffsetFromToday: Int): Pair<Long, Long> {
    val cal = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
        add(Calendar.DAY_OF_YEAR, dayOffsetFromToday)
    }
    val start = cal.timeInMillis
    val end = start + 24L * 3600L * 1000L - 1L
    return start to end
}

private fun dayRangeMsFromString(dayStr: String): Pair<Long, Long>? {
    return runCatching {
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
        val d = fmt.parse(dayStr) ?: return null
        val cal = Calendar.getInstance().apply {
            time = d
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val start = cal.timeInMillis
        start to (start + 24L * 3600L * 1000L - 1L)
    }.getOrNull()
}

class MainActivity : ComponentActivity() {
    companion object {
        const val EXTRA_OPEN_REVIEW = "open_review"
    }

    private var openReviewSignal by mutableStateOf(0)

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
                    openReviewSignal = openReviewSignal,
                    themeMode = themeMode,
                    onThemeModeChange = { next ->
                        themeMode = next
                        prefs.edit().putString("theme_mode", next).apply()
                    },
                    onRequestNotificationPermission = {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            notifPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                        }
                    },
                    onOpenQuickCapture = {
                        startActivity(Intent(this, QuickCaptureActivity::class.java))
                    },
                    onEditNote = { note ->
                        val intent = Intent(this, QuickCaptureActivity::class.java).apply {
                            putExtra(QuickCaptureActivity.EXTRA_EDIT_NOTE_ID, note.id)
                            putExtra(QuickCaptureActivity.EXTRA_EDIT_CONTENT, note.content)
                        }
                        startActivity(intent)
                    }
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra(EXTRA_OPEN_REVIEW, false)) {
            openReviewSignal++
        }
    }

    override fun onStart() {
        super.onStart()
        // Foreground ON_RESUME handles immediate sync + UI refresh directly (avoiding WorkManager race).
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FlomoMobileApp(
    initialReviewMode: Boolean,
    openReviewSignal: Int,
    themeMode: String,
    onThemeModeChange: (String) -> Unit,
    onRequestNotificationPermission: () -> Unit,
    onOpenQuickCapture: () -> Unit,
    onEditNote: (WhimNote) -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val listState = rememberLazyListState()
    var previousTopNoteId by remember { mutableStateOf<String?>(null) }
    var isPullRefreshing by remember { mutableStateOf(false) }
    val showScrollToTop by remember { derivedStateOf { listState.firstVisibleItemIndex >= 4 } }

    var activeTab by remember { mutableStateOf<MobileTab>(if (initialReviewMode) MobileTab.Review else MobileTab.All) }
    var reviewOffsetDays by remember { mutableStateOf(0) }
    var searchQuery by remember { mutableStateOf("") }
    var showSearch by remember { mutableStateOf(false) }
    var showSettingsScreen by remember { mutableStateOf(false) }
    var settingsFocusSection by remember { mutableStateOf(SettingsFocusSection.ALL) }
    var reviewReminders by remember { mutableStateOf(DailyReviewScheduler.getReminders(context)) }
    var exactAlarmGranted by remember { mutableStateOf(DailyReviewScheduler.canScheduleExactAlarms(context)) }
    var notifPermissionGranted by remember { mutableStateOf(DailyReviewReceiver.hasNotificationPermission(context)) }
    var previewImagePath by remember { mutableStateOf<String?>(null) }
    var lastDeletedNoteId by remember { mutableStateOf<String?>(null) }
    var undoDismissJob by remember { mutableStateOf<Job?>(null) }
    var randomSeed by remember { mutableStateOf(0) }

    var stats by remember { mutableStateOf(WhimStats()) }
    var displayedNotes by remember { mutableStateOf<List<WhimNote>>(emptyList()) }
    var hasMore by remember { mutableStateOf(false) }
    var isLoadingMore by remember { mutableStateOf(false) }
    var nextCursor by remember { mutableStateOf<WhimNoteCursor?>(null) }
    var filterGen by remember { mutableStateOf(0) }
    val pageSize = 50

    var tagTree by remember { mutableStateOf<List<WhimTagNode>>(emptyList()) }
    var pairedPeers by remember { mutableStateOf<List<WhimSyncPeer>>(emptyList()) }
    var syncToast by remember { mutableStateOf("") }
    var syncToastJob by remember { mutableStateOf<Job?>(null) }
    var peerStatuses by remember { mutableStateOf<List<com.whim.app.core.WhimPeerSyncStatus>>(emptyList()) }
    var syncHealth by remember { mutableStateOf(WhimSyncHealthStatus()) }
    var isSyncingNow by remember { mutableStateOf(false) }
    var latestUpdateRelease by remember { mutableStateOf<com.whim.app.update.ReleaseInfo?>(null) }
    var hasAppUpdate by remember { mutableStateOf(false) }
    var lastLoadedVersion by remember { mutableStateOf(-1L) }
    var foregroundSyncTrigger by remember { mutableStateOf(0) }

    fun buildFilterForTab(tab: MobileTab, cursor: WhimNoteCursor?): WhimListFilter? {
        return when (tab) {
            MobileTab.All -> WhimListFilter(query = searchQuery, limit = pageSize, cursor = cursor)
            MobileTab.Archived -> WhimListFilter(query = searchQuery, onlyArchived = true, limit = pageSize, cursor = cursor)
            MobileTab.Review -> {
                val (fromMs, toMs) = dayRangeMs(reviewOffsetDays)
                WhimListFilter(
                    query = searchQuery,
                    dateFromMs = fromMs,
                    dateToMs = toMs,
                    includeArchived = true,
                    limit = pageSize,
                    cursor = cursor
                )
            }
            is MobileTab.Day -> {
                val range = dayRangeMsFromString(tab.dayStr) ?: return null
                WhimListFilter(
                    query = searchQuery,
                    dateFromMs = range.first,
                    dateToMs = range.second,
                    includeArchived = true,
                    limit = pageSize,
                    cursor = cursor
                )
            }
            is MobileTab.Tag -> WhimListFilter(query = searchQuery, tagPrefix = tab.path, limit = pageSize, cursor = cursor)
            MobileTab.Random -> null
        }
    }

    suspend fun refreshMetadata() {
        runCatching {
            stats = WhimCoreBridge.getStats(90)
            tagTree = WhimCoreBridge.listTagTree()
            pairedPeers = WhimCoreBridge.listPairedPeers()
        }
    }

    suspend fun loadFirstPage() {
        val gen = ++filterGen
        nextCursor = null
        hasMore = false
        isLoadingMore = false
        runCatching {
            val tab = activeTab
            if (tab == MobileTab.Random) {
                val rnd = WhimCoreBridge.listRandomNotes(query = searchQuery, limit = 12)
                if (filterGen == gen) {
                    displayedNotes = rnd
                    hasMore = false
                    nextCursor = null
                }
            } else {
                val filter = buildFilterForTab(tab, null)
                if (filter == null) {
                    if (filterGen == gen) displayedNotes = emptyList()
                    return@runCatching
                }
                val page = WhimCoreBridge.listNotesPage(filter)
                if (filterGen == gen) {
                    displayedNotes = page.notes
                    hasMore = page.hasMore
                    nextCursor = page.nextCursor
                }
            }
        }
    }

    fun loadMore() {
        val cursor = nextCursor ?: return
        if (!hasMore || isLoadingMore) return
        val filter = buildFilterForTab(activeTab, cursor) ?: return
        isLoadingMore = true
        val gen = filterGen
        scope.launch {
            runCatching {
                val page = WhimCoreBridge.listNotesPage(filter)
                if (filterGen == gen) {
                    val existing = displayedNotes.map { it.id }.toHashSet()
                    val fresh = page.notes.filter { it.id !in existing }
                    displayedNotes = displayedNotes + fresh
                    hasMore = page.hasMore && fresh.isNotEmpty()
                    nextCursor = page.nextCursor
                }
            }
            if (filterGen == gen) {
                isLoadingMore = false
            }
        }
    }

    fun reload() {
        scope.launch {
            lastLoadedVersion = WhimCoreBridge.dataVersion()
            refreshMetadata()
            loadFirstPage()
        }
    }

    DisposableEffect(Unit) {
        MobileTagDispatch.onTap = { path -> activeTab = MobileTab.Tag(path) }
        onDispose { MobileTagDispatch.onTap = null }
    }

    LaunchedEffect(Unit) {
        refreshMetadata()
        delay(3000L)
        if (GitHubUpdater.shouldAutoCheck(context)) {
            GitHubUpdater.markAutoChecked(context)
            val res = GitHubUpdater.checkLatest()
            if (res.hasUpdate && res.release != null && !GitHubUpdater.isVersionSkipped(context, res.release.tagName)) {
                latestUpdateRelease = res.release
                hasAppUpdate = true
            }
        }
    }

    LaunchedEffect(openReviewSignal) {
        if (openReviewSignal > 0) {
            activeTab = MobileTab.Review
            reviewOffsetDays = 0
        }
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                exactAlarmGranted = DailyReviewScheduler.canScheduleExactAlarms(context)
                notifPermissionGranted = DailyReviewReceiver.hasNotificationPermission(context)
                reviewReminders = DailyReviewScheduler.getReminders(context)
                // Tear down any half-open SSE socket from sleep/background and trigger immediate foreground sync
                WhimCoreBridge.reconnectEvents()
                reload()
                foregroundSyncTrigger++
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Reconnect SSE & sync immediately whenever Wi-Fi comes back online
    DisposableEffect(context) {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                WhimCoreBridge.reconnectEvents()
                scope.launch { foregroundSyncTrigger++ }
            }
        }
        val registered = runCatching {
            val req = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            cm?.registerNetworkCallback(req, callback)
            cm != null
        }.getOrDefault(false)
        onDispose {
            if (registered) {
                runCatching { cm?.unregisterNetworkCallback(callback) }
            }
        }
    }

    LaunchedEffect(activeTab, reviewOffsetDays, searchQuery, randomSeed) {
        if (searchQuery.isNotEmpty()) {
            delay(180L)
        }
        loadFirstPage()
        if (listState.firstVisibleItemIndex > 0) {
            listState.scrollToItem(0)
        }
    }

    // Single snapshotFlow observer for pagination instead of per-item LaunchedEffect
    LaunchedEffect(listState, hasMore, isLoadingMore, displayedNotes.size) {
        if (!hasMore || isLoadingMore || displayedNotes.isEmpty()) return@LaunchedEffect
        snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1 }
            .distinctUntilChanged()
            .collect { lastVisible ->
                if (lastVisible >= displayedNotes.size - 6 && hasMore && !isLoadingMore) {
                    loadMore()
                }
            }
    }

    // Pre-warm image aspect ratios & Coil memory cache so scrolling onto image cards never hitches
    LaunchedEffect(displayedNotes) {
        if (displayedNotes.isEmpty()) return@LaunchedEffect
        withContext(Dispatchers.IO) {
            val loader = context.imageLoader
            var prefetched = 0
            for (note in displayedNotes) {
                for (att in note.attachments) {
                    val path = att.localPath
                    if (path.isNotEmpty()) {
                        MobileImageBoundsCache.aspectRatio(path)
                        loader.enqueue(
                            ImageRequest.Builder(context)
                                .data(File(path))
                                .size(960, 960)
                                .precision(Precision.INEXACT)
                                .build()
                        )
                        prefetched++
                        if (prefetched >= 24) return@withContext
                    }
                }
            }
        }
    }

    // Auto-scroll to top when a newly synced note arrives at index 0
    val currentTopNoteId = displayedNotes.firstOrNull()?.id
    LaunchedEffect(currentTopNoteId) {
        if (currentTopNoteId != null && previousTopNoteId != null && currentTopNoteId != previousTopNoteId && listState.firstVisibleItemIndex <= 1) {
            listState.animateScrollToItem(0)
        }
        previousTopNoteId = currentTopNoteId
    }

    // Immediate foreground catch-up sync on every ON_RESUME / Wi-Fi reconnect
    LaunchedEffect(foregroundSyncTrigger) {
        if (foregroundSyncTrigger == 0) return@LaunchedEffect
        val peers = runCatching { WhimCoreBridge.listPairedPeers() }.getOrDefault(emptyList())
        pairedPeers = peers
        if (peers.isEmpty()) {
            syncHealth = WhimSyncHealthStatus(state = "unpaired", connected = false)
            return@LaunchedEffect
        }
        val res = runCatching { WhimCoreBridge.syncOnce(timeoutSec = 6) }.getOrNull()
        runCatching { pairedPeers = WhimCoreBridge.listPairedPeers() }
        runCatching { syncHealth = WhimCoreBridge.checkSyncHealth(activeProbe = true) }
        if (res != null) {
            peerStatuses = res.peers
            if (res.notesMerged > 0 || res.blobsDownloaded > 0 || WhimCoreBridge.dataVersion() != lastLoadedVersion) {
                reload()
                WhimWidgetProvider.refreshAll(context)
            }
        } else if (WhimCoreBridge.dataVersion() != lastLoadedVersion) {
            reload()
        }
    }

    // Real-time ping/pong liveness monitor for the top-bar sync status indicator
    LaunchedEffect(pairedPeers.size) {
        var tick = 0
        while (isActive) {
            val activeProbe = (tick % 3 == 0)
            tick++
            runCatching { pairedPeers = WhimCoreBridge.listPairedPeers() }
            if (pairedPeers.isEmpty()) {
                syncHealth = WhimSyncHealthStatus(state = "unpaired", connected = false)
                delay(4000L)
                continue
            }
            runCatching { syncHealth = WhimCoreBridge.checkSyncHealth(activeProbe = activeProbe) }
            delay(5000L)
        }
    }

    // Real-time multi-host SSE push loop: wakes up in < 50ms when any paired Mac changes a note
    // or sends an unpair event, with a 15s fallback sync in case of Wi-Fi hiccups.
    LaunchedEffect(pairedPeers.size) {
        while (isActive) {
            if (pairedPeers.isNotEmpty()) {
                val res = runCatching { WhimCoreBridge.syncOnce(timeoutSec = 6) }.getOrNull()
                runCatching { pairedPeers = WhimCoreBridge.listPairedPeers() }
                runCatching { syncHealth = WhimCoreBridge.checkSyncHealth(activeProbe = false) }
                if (res != null) {
                    peerStatuses = res.peers
                    if (res.notesMerged > 0 || res.blobsDownloaded > 0 || WhimCoreBridge.dataVersion() != lastLoadedVersion) {
                        reload()
                        WhimWidgetProvider.refreshAll(context)
                    }
                } else if (WhimCoreBridge.dataVersion() != lastLoadedVersion) {
                    reload()
                }
                WhimCoreBridge.waitForChange(timeoutSec = 15)
                runCatching { pairedPeers = WhimCoreBridge.listPairedPeers() }
                if (WhimCoreBridge.dataVersion() != lastLoadedVersion) {
                    reload()
                }
            } else {
                delay(2500L)
            }
        }
    }

    val selectedHeatmapDay = (activeTab as? MobileTab.Day)?.dayStr

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

                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        StatBlock("${stats.totalNotes}", "笔记")
                        StatBlock("${stats.totalTags}", "标签")
                        StatBlock("${stats.activeDays}", "天")
                        Spacer(Modifier.width(12.dp))
                    }

                    Spacer(Modifier.height(14.dp))

                    MobileHeatmap(
                        dailyCounts = stats.dailyCounts,
                        selectedDay = selectedHeatmapDay,
                        onSelectDay = { dayStr ->
                            activeTab = MobileTab.Day(dayStr)
                            scope.launch { drawerState.close() }
                        }
                    )

                    Spacer(Modifier.height(16.dp))

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
                    DrawerNavRow(Icons.Rounded.Archive, "已归档", activeTab == MobileTab.Archived) {
                        activeTab = MobileTab.Archived
                        scope.launch { drawerState.close() }
                    }
                    DrawerNavRow(Icons.Rounded.Settings, "设置 · ${if (pairedPeers.isNotEmpty()) "已配对 ${pairedPeers.size} 台" else "未配对"} · v${GitHubUpdater.CURRENT_VERSION}", false) {
                        settingsFocusSection = SettingsFocusSection.ALL
                        showSettingsScreen = true
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
                    Row(
                        modifier = Modifier.weight(1f),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
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
                                MobileTab.Archived -> "已归档"
                                is MobileTab.Day -> "日期 · ${tab.dayStr}"
                                is MobileTab.Tag -> "#${tab.path}"
                            },
                            style = t.title,
                            color = c.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        if (activeTab is MobileTab.Day) {
                            Text(
                                "清除",
                                style = t.meta,
                                color = c.tagText,
                                modifier = Modifier.clickable { activeTab = MobileTab.All }
                            )
                        }
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        val syncDotColor = when {
                            isSyncingNow -> Color(0xFFF59E0B)
                            syncHealth.connected -> Color(0xFF34D399)
                            syncHealth.state == "wrong_code" -> Color(0xFFF59E0B)
                            else -> c.textMuted
                        }
                        val syncTextColor = when {
                            syncHealth.connected -> Color(0xFF34D399)
                            syncHealth.state == "wrong_code" -> Color(0xFFF59E0B)
                            else -> c.textSecondary
                        }
                        val syncStatusText = when {
                            isSyncingNow -> "同步中"
                            syncHealth.connected -> "已同步"
                            syncHealth.state == "wrong_code" -> "需重配"
                            syncHealth.state == "unpaired" || pairedPeers.isEmpty() -> "未配对"
                            else -> "未连接"
                        }
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(14.dp))
                                .background(if (syncHealth.connected) c.accent.copy(alpha = 0.16f) else c.card)
                                .border(
                                    width = 0.8.dp,
                                    color = if (syncHealth.connected) Color(0xFF34D399).copy(alpha = 0.35f) else c.border,
                                    shape = RoundedCornerShape(14.dp)
                                )
                                .clickable(enabled = !isSyncingNow) {
                                    if (pairedPeers.isEmpty() || syncHealth.state == "wrong_code") {
                                        settingsFocusSection = SettingsFocusSection.SYNC
                                        showSettingsScreen = true
                                    } else {
                                        scope.launch {
                                            isSyncingNow = true
                                            syncToast = "正在检测连接并同步..."
                                            val res = runCatching { WhimCoreBridge.syncOnce() }.getOrNull()
                                            runCatching { pairedPeers = WhimCoreBridge.listPairedPeers() }
                                            val health = runCatching { WhimCoreBridge.checkSyncHealth(activeProbe = true) }.getOrNull()
                                            if (health != null) syncHealth = health
                                            if (res != null) peerStatuses = res.peers
                                            isSyncingNow = false
                                            syncToast = when {
                                                health != null && health.connected -> {
                                                    val peerLabel = health.peerName.ifEmpty { "局域网设备" }
                                                    val rttPart = if (health.rttMs > 0) " · ${health.rttMs}ms" else ""
                                                    val mergePart = if ((res?.notesMerged ?: 0) > 0) " · 合并 ${res!!.notesMerged} 条" else ""
                                                    "已同步 · $peerLabel$rttPart$mergePart"
                                                }
                                                health?.state == "wrong_code" -> "配对码不匹配，请在同步设置中核对"
                                                res != null && res.peers.isNotEmpty() -> res.peers.first().message
                                                else -> "未连接到 Mac（心跳无响应）"
                                            }
                                            reload()
                                            WhimWidgetProvider.refreshAll(context)
                                            syncToastJob?.cancel()
                                            syncToastJob = scope.launch {
                                                delay(2600L)
                                                syncToast = ""
                                            }
                                        }
                                    }
                                }
                                .padding(horizontal = 8.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(6.5.dp)
                                    .clip(CircleShape)
                                    .background(syncDotColor)
                            )
                            Icon(
                                Icons.Rounded.Sync,
                                contentDescription = "同步",
                                tint = syncTextColor,
                                modifier = Modifier.size(14.dp)
                            )
                            Text(
                                text = syncStatusText,
                                fontSize = 11.sp,
                                fontWeight = if (syncHealth.connected) FontWeight.Medium else FontWeight.Normal,
                                color = syncTextColor,
                                maxLines = 1
                            )
                        }
                        Icon(
                            Icons.Rounded.Search,
                            contentDescription = "搜索",
                            tint = c.textSecondary,
                            modifier = Modifier
                                .size(22.dp)
                                .clickable { showSearch = !showSearch }
                        )
                        Box(
                            modifier = Modifier.clickable {
                                settingsFocusSection = if (hasAppUpdate) SettingsFocusSection.ABOUT else SettingsFocusSection.ALL
                                showSettingsScreen = true
                            }
                        ) {
                            Icon(
                                Icons.Rounded.Settings,
                                contentDescription = "设置",
                                tint = c.textSecondary,
                                modifier = Modifier.size(22.dp)
                            )
                            if (hasAppUpdate) {
                                Box(
                                    modifier = Modifier
                                        .align(Alignment.TopEnd)
                                        .size(7.dp)
                                        .clip(CircleShape)
                                        .background(Color(0xFFEF4444))
                                )
                            }
                        }
                    }
                }

                if (syncToast.isNotEmpty()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 2.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(c.card)
                            .padding(horizontal = 12.dp, vertical = 7.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(syncToast, style = t.meta, color = c.textSecondary)
                        Text(
                            "同步设置",
                            style = t.meta,
                            color = c.tagText,
                            modifier = Modifier.clickable {
                                settingsFocusSection = SettingsFocusSection.SYNC
                                showSettingsScreen = true
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
                            modifier = Modifier.weight(1f),
                            decorationBox = { inner ->
                                if (searchQuery.isEmpty()) Text("搜索笔记或 #标签...", style = t.body, color = c.textMuted)
                                inner()
                            }
                        )
                        if (searchQuery.isNotEmpty()) {
                            Icon(
                                Icons.Rounded.Close,
                                contentDescription = "清空",
                                tint = c.textMuted,
                                modifier = Modifier
                                    .size(16.dp)
                                    .clickable { searchQuery = "" }
                            )
                        }
                    }
                }

                if (activeTab == MobileTab.Review) {
                    val reviewLabel = remember(reviewOffsetDays) {
                        val (startMs, _) = dayRangeMs(reviewOffsetDays)
                        val ds = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date(startMs))
                        if (reviewOffsetDays == 0) "$ds · 今天" else ds
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(c.card)
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(
                                Icons.Rounded.ChevronLeft,
                                contentDescription = "前一天",
                                tint = c.textPrimary,
                                modifier = Modifier
                                    .size(24.dp)
                                    .clickable { reviewOffsetDays -= 1 }
                            )
                            Text(reviewLabel, style = t.body, color = c.textPrimary, fontWeight = FontWeight.Medium)
                            Icon(
                                Icons.Rounded.ChevronRight,
                                contentDescription = "后一天",
                                tint = if (reviewOffsetDays < 0) c.textPrimary else c.textMuted,
                                modifier = Modifier
                                    .size(24.dp)
                                    .clickable(enabled = reviewOffsetDays < 0) { reviewOffsetDays += 1 }
                            )
                        }
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (reviewOffsetDays < 0) {
                                Text(
                                    "回到今天",
                                    style = t.meta,
                                    color = c.tagText,
                                    modifier = Modifier.clickable { reviewOffsetDays = 0 }
                                )
                            } else {
                                Text("共 ${displayedNotes.size} 条", style = t.meta, color = c.textSecondary)
                            }
                            val remindersActive = DailyReviewScheduler.hasEnabledReminders(reviewReminders)
                            Row(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(if (remindersActive) c.tagBg else c.canvas)
                                    .clickable {
                                        settingsFocusSection = SettingsFocusSection.REVIEW
                                        showSettingsScreen = true
                                    }
                                    .padding(horizontal = 8.dp, vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                Icon(
                                    Icons.Rounded.Notifications,
                                    contentDescription = "提醒设置",
                                    tint = if (remindersActive) c.tagText else c.textMuted,
                                    modifier = Modifier.size(13.dp)
                                )
                                Text(
                                    DailyReviewScheduler.formatSummary(reviewReminders),
                                    style = t.meta,
                                    color = if (remindersActive) c.tagText else c.textMuted,
                                    fontWeight = FontWeight.Medium
                                )
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

                if (activeTab == MobileTab.Review || activeTab == MobileTab.Random) {
                    MobileCardDeck(
                        notes = displayedNotes,
                        isRandomMode = activeTab == MobileTab.Random,
                        resetKey = "$activeTab|$reviewOffsetDays|$randomSeed|${displayedNotes.firstOrNull()?.id.orEmpty()}|${displayedNotes.size}",
                        onTapImage = { path -> previewImagePath = path },
                        onEdit = { note -> onEditNote(note) },
                        onTogglePin = { note ->
                            scope.launch {
                                WhimCoreBridge.updateNote(note.id, pinned = !note.pinned)
                                reload()
                                runCatching { WhimCoreBridge.syncOnce(timeoutSec = 3) }
                                SyncWorker.enqueueImmediate(context)
                            }
                        },
                        onToggleArchive = { note ->
                            scope.launch {
                                WhimCoreBridge.updateNote(note.id, archived = !note.archived)
                                reload()
                                runCatching { WhimCoreBridge.syncOnce(timeoutSec = 3) }
                                SyncWorker.enqueueImmediate(context)
                            }
                        },
                        onCopy = { note ->
                            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.setPrimaryClip(ClipData.newPlainText("whim", note.content))
                        },
                        onDelete = { note ->
                            scope.launch {
                                WhimCoreBridge.updateNote(note.id, deleted = true)
                                reload()
                                lastDeletedNoteId = note.id
                                undoDismissJob?.cancel()
                                undoDismissJob = scope.launch {
                                    delay(6000L)
                                    lastDeletedNoteId = null
                                }
                                runCatching { WhimCoreBridge.syncOnce(timeoutSec = 3) }
                                SyncWorker.enqueueImmediate(context)
                            }
                        },
                        onReshuffle = { randomSeed++ },
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f)
                    )
                } else {
                // Flomo Note Card Feed with Pull-to-Refresh LAN sync
                PullToRefreshBox(
                    isRefreshing = isPullRefreshing,
                    onRefresh = {
                        scope.launch {
                            isPullRefreshing = true
                            runCatching {
                                val res = WhimCoreBridge.syncOnce(timeoutSec = 4)
                                peerStatuses = res.peers
                            }
                            refreshMetadata()
                            loadFirstPage()
                            WhimWidgetProvider.refreshAll(context)
                            isPullRefreshing = false
                        }
                    },
                    modifier = Modifier.fillMaxSize()
                ) {
                    LazyColumn(
                        state = listState,
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 96.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        if (displayedNotes.isEmpty()) {
                            item(key = "__empty__", contentType = "empty") {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(top = 80.dp),
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    verticalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Text(
                                        if (searchQuery.isEmpty()) "暂无笔记，点击右下角记下第一个想法" else "未找到匹配“$searchQuery”的笔记",
                                        style = t.body,
                                        color = c.textMuted
                                    )
                                    if (searchQuery.isNotEmpty()) {
                                        Text(
                                            "清除搜索",
                                            style = t.meta,
                                            color = c.tagText,
                                            modifier = Modifier.clickable { searchQuery = "" }
                                        )
                                    }
                                }
                            }
                        } else {
                            items(
                                items = displayedNotes,
                                key = { it.id },
                                contentType = { "note_card" }
                            ) { note ->
                                FlomoMobileNoteCard(
                                    note = note,
                                    modifier = Modifier.animateItem(),
                                    onTapTag = { path -> activeTab = MobileTab.Tag(path) },
                                    onTapImage = { path -> previewImagePath = path },
                                    onEdit = { onEditNote(note) },
                                    onTogglePin = {
                                        scope.launch {
                                            WhimCoreBridge.updateNote(note.id, pinned = !note.pinned)
                                            reload()
                                            runCatching { WhimCoreBridge.syncOnce(timeoutSec = 3) }
                                            SyncWorker.enqueueImmediate(context)
                                        }
                                    },
                                    onToggleArchive = {
                                        scope.launch {
                                            WhimCoreBridge.updateNote(note.id, archived = !note.archived)
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
                                            lastDeletedNoteId = note.id
                                            undoDismissJob?.cancel()
                                            undoDismissJob = scope.launch {
                                                delay(6000L)
                                                lastDeletedNoteId = null
                                            }
                                            runCatching { WhimCoreBridge.syncOnce(timeoutSec = 3) }
                                            SyncWorker.enqueueImmediate(context)
                                        }
                                    }
                                )
                            }
                            item(key = "__footer__", contentType = "footer") {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(vertical = 12.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    when {
                                        isLoadingMore -> Text("正在加载更多...", style = t.meta, color = c.textMuted)
                                        hasMore -> Text(
                                            "加载更多",
                                            style = t.meta,
                                            color = c.tagText,
                                            modifier = Modifier.clickable { loadMore() }
                                        )
                                        displayedNotes.size >= 20 -> Text("已加载全部 ${displayedNotes.size} 条", style = t.meta, color = c.textMuted)
                                    }
                                }
                            }
                        }
                    }
                }
                }
            }

            // 6-second Undo Delete Snackbar
            lastDeletedNoteId?.let { deletedId ->
                Row(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 32.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(c.card)
                        .border(1.dp, c.border, RoundedCornerShape(10.dp))
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("已删除一条笔记", style = t.body, color = c.textPrimary)
                    Text(
                        "撤销",
                        style = t.body,
                        color = c.accent,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clickable {
                            undoDismissJob?.cancel()
                            lastDeletedNoteId = null
                            scope.launch {
                                WhimCoreBridge.updateNote(deletedId, deleted = false)
                                reload()
                                runCatching { WhimCoreBridge.syncOnce(timeoutSec = 3) }
                                SyncWorker.enqueueImmediate(context)
                            }
                        }
                    )
                }
            }

            // Floating action column: scroll-to-top + sage-green capture FAB
            Column(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 20.dp, bottom = 28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                AnimatedVisibility(
                    visible = showScrollToTop,
                    enter = fadeIn(),
                    exit = fadeOut()
                ) {
                    Box(
                        modifier = Modifier
                            .size(40.dp)
                            .clip(CircleShape)
                            .background(c.card)
                            .border(1.dp, c.border, CircleShape)
                            .clickable { scope.launch { listState.animateScrollToItem(0) } },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Rounded.KeyboardArrowUp,
                            contentDescription = "回到顶部",
                            tint = c.textSecondary,
                            modifier = Modifier.size(22.dp)
                        )
                    }
                }

                Box(
                    modifier = Modifier
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

    if (showSettingsScreen) {
        MobileSettingsScreen(
            focusSection = settingsFocusSection,
            themeMode = themeMode,
            onThemeModeChange = onThemeModeChange,
            reviewReminders = reviewReminders,
            onReviewRemindersChange = { reviewReminders = it },
            notifPermissionGranted = notifPermissionGranted,
            exactAlarmGranted = exactAlarmGranted,
            onRequestNotificationPermission = onRequestNotificationPermission,
            pairedPeers = pairedPeers,
            onPairedPeersUpdated = { pairedPeers = it },
            syncHealth = syncHealth,
            onSyncHealthUpdated = { syncHealth = it },
            initialRelease = latestUpdateRelease,
            onUpdateBadgeDismissed = {
                hasAppUpdate = false
                latestUpdateRelease = null
            },
            onSyncCompleted = { reload() },
            onBack = { showSettingsScreen = false }
        )
    }

    // Full-screen Image Lightbox Dialog
    previewImagePath?.let { path ->
        Dialog(
            onDismissRequest = { previewImagePath = null },
            properties = DialogProperties(usePlatformDefaultWidth = false)
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color(0xE6000000))
                    .clickable { previewImagePath = null },
                contentAlignment = Alignment.Center
            ) {
                AsyncImage(
                    model = File(path),
                    contentDescription = "图片大图预览",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                )
                Box(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .statusBarsPadding()
                        .padding(16.dp)
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(Color(0x88000000))
                        .clickable { previewImagePath = null },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Rounded.Close, contentDescription = "关闭", tint = Color.White, modifier = Modifier.size(20.dp))
                }
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
private fun MobileHeatmap(
    dailyCounts: Map<String, Int>,
    selectedDay: String?,
    onSelectDay: (String) -> Unit
) {
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
                    val isSelected = key == selectedDay
                    Box(
                        modifier = Modifier
                            .size(14.dp)
                            .clip(RoundedCornerShape(3.dp))
                            .background(c.heatmapColor(cnt))
                            .then(
                                when {
                                    isSelected -> Modifier.border(1.5.dp, c.tagText, RoundedCornerShape(3.dp))
                                    isToday -> Modifier.border(1.dp, c.textSecondary, RoundedCornerShape(3.dp))
                                    else -> Modifier
                                }
                            )
                            .clickable { onSelectDay(key) }
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

private val cardTimeFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

private object MobileImageBoundsCache {
    private val ratioCache = LruCache<String, Float>(320)

    fun aspectRatio(path: String): Float {
        ratioCache.get(path)?.let { return it }
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, opts)
        val ratio = if (opts.outWidth > 0 && opts.outHeight > 0) {
            (opts.outWidth.toFloat() / opts.outHeight.toFloat()).coerceIn(0.6f, 2.5f)
        } else {
            1.6f
        }
        ratioCache.put(path, ratio)
        return ratio
    }
}

@Immutable
private sealed class MobileMdChunk {
    data class RichText(val text: AnnotatedString) : MobileMdChunk()
    data class CodeBlock(val lang: String, val code: String) : MobileMdChunk()
}

@Immutable
private sealed class MobileCardBlock {
    data class TextBlock(val chunks: List<MobileMdChunk>) : MobileCardBlock()
    data class ImageBlock(val path: String) : MobileCardBlock()
}

private object MobileTagDispatch {
    @Volatile
    var onTap: ((String) -> Unit)? = null
}

@Immutable
private data class ParsedMobileCard(
    val timeStr: String,
    val blocks: List<MobileCardBlock>,
    val trailing: List<WhimAttachment>
)

private object MobileCardParseCache {
    private val cache = LruCache<String, ParsedMobileCard>(320)

    fun getOrParse(
        note: WhimNote,
        primary: Color,
        secondary: Color,
        muted: Color,
        accent: Color,
        codeBg: Color,
        codeFg: Color
    ): ParsedMobileCard {
        val key = "${note.id}:${note.updatedAt}:inline:${primary.value}:${note.attachments.size}"
        cache.get(key)?.let { return it }
        val parsed = parse(note, primary, secondary, muted, accent, codeBg, codeFg)
        cache.put(key, parsed)
        return parsed
    }

    private fun parse(
        note: WhimNote,
        primary: Color,
        secondary: Color,
        muted: Color,
        accent: Color,
        codeBg: Color,
        codeFg: Color
    ): ParsedMobileCard {
        val timeStr = Instant.ofEpochMilli(note.createdAt)
            .atZone(ZoneId.systemDefault())
            .format(cardTimeFormatter)

        val displayBody = note.content.lines()
            .map { line -> if (line.isBlank()) "" else line.trimEnd() }
            .dropWhile { it.isEmpty() }
            .dropLastWhile { it.isEmpty() }
            .joinToString("\n")

        val pathByHash = note.attachments.associate { it.sha256 to it.localPath }
        val blocks = mutableListOf<MobileCardBlock>()
        val referenced = HashSet<String>()
        var cursor = 0

        for (m in mobileBlobRegex.findAll(displayBody)) {
            if (m.range.first > cursor) {
                val seg = displayBody.substring(cursor, m.range.first).trim('\n')
                if (seg.isNotBlank()) {
                    blocks.add(
                        MobileCardBlock.TextBlock(
                            parseMarkdownChunks(seg, primary, secondary, muted, accent, codeBg, codeFg)
                        )
                    )
                }
            }
            val hash = m.groupValues[1]
            referenced.add(hash)
            val path = pathByHash[hash].orEmpty()
            if (path.isNotEmpty()) {
                blocks.add(MobileCardBlock.ImageBlock(path))
            }
            cursor = m.range.last + 1
        }
        if (cursor < displayBody.length) {
            val tail = displayBody.substring(cursor).trim('\n')
            if (tail.isNotBlank()) {
                blocks.add(
                    MobileCardBlock.TextBlock(
                        parseMarkdownChunks(tail, primary, secondary, muted, accent, codeBg, codeFg)
                    )
                )
            }
        }

        val trailing = note.attachments.filter { it.sha256 !in referenced && it.localPath.isNotEmpty() }
        return ParsedMobileCard(timeStr = timeStr, blocks = blocks, trailing = trailing)
    }

    private fun parseMarkdownChunks(
        text: String,
        primary: Color,
        secondary: Color,
        muted: Color,
        accent: Color,
        codeBg: Color,
        codeFg: Color
    ): List<MobileMdChunk> {
        val effective = text.lines()
        val out = ArrayList<MobileMdChunk>(2)
        var inCode = false
        var codeLang = ""
        val codeBuf = mutableListOf<String>()

        var textBuilder = AnnotatedString.Builder()
        var hasText = false

        fun flushText() {
            if (hasText) {
                out.add(MobileMdChunk.RichText(textBuilder.toAnnotatedString()))
                textBuilder = AnnotatedString.Builder()
                hasText = false
            }
        }

        fun startNewLine() {
            if (hasText) textBuilder.append('\n')
            hasText = true
        }

        for (line in effective) {
            val trimmed = line.trim()
            if (trimmed.startsWith("```")) {
                if (!inCode) {
                    flushText()
                    inCode = true
                    codeLang = trimmed.drop(3).trim()
                    codeBuf.clear()
                } else {
                    out.add(MobileMdChunk.CodeBlock(codeLang, codeBuf.joinToString("\n")))
                    inCode = false
                    codeLang = ""
                    codeBuf.clear()
                }
                continue
            }
            if (inCode) {
                codeBuf.add(line)
                continue
            }

            var spaces = 0
            for (ch in line) {
                if (ch == ' ') spaces++ else if (ch == '\t') spaces += 2 else break
            }
            val level = (spaces / 2).coerceAtMost(6)
            val indentStr = if (level > 0) "    ".repeat(level) else ""
            val bulletGlyph = when (level % 3) {
                0 -> "•"
                1 -> "◦"
                else -> "▪"
            }

            startNewLine()
            when {
                trimmed.isEmpty() -> Unit
                trimmed == "---" || trimmed == "***" || trimmed == "___" -> {
                    textBuilder.withStyle(SpanStyle(color = muted.copy(alpha = 0.5f), fontSize = 12.sp)) {
                        append("────────────────────────")
                    }
                }
                trimmed.startsWith("#### ") -> {
                    textBuilder.withStyle(SpanStyle(color = primary, fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold)) {
                        appendInlineMarkdown(trimmed.drop(5), codeBg, codeFg)
                    }
                }
                trimmed.startsWith("### ") -> {
                    textBuilder.withStyle(SpanStyle(color = primary, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)) {
                        appendInlineMarkdown(trimmed.drop(4), codeBg, codeFg)
                    }
                }
                trimmed.startsWith("## ") -> {
                    textBuilder.withStyle(SpanStyle(color = primary, fontSize = 17.sp, fontWeight = FontWeight.Bold)) {
                        appendInlineMarkdown(trimmed.drop(3), codeBg, codeFg)
                    }
                }
                trimmed.startsWith("# ") -> {
                    textBuilder.withStyle(SpanStyle(color = primary, fontSize = 18.5.sp, fontWeight = FontWeight.Bold)) {
                        appendInlineMarkdown(trimmed.drop(2), codeBg, codeFg)
                    }
                }
                trimmed.startsWith("- [ ] ") || trimmed.startsWith("- [x] ") || trimmed.startsWith("- [X] ") -> {
                    val done = !trimmed.startsWith("- [ ] ")
                    if (indentStr.isNotEmpty()) textBuilder.append(indentStr)
                    textBuilder.withStyle(SpanStyle(color = if (done) accent else muted)) {
                        append(if (done) "☑ " else "☐ ")
                    }
                    textBuilder.withStyle(
                        SpanStyle(
                            color = if (done) secondary else primary,
                            textDecoration = if (done) TextDecoration.LineThrough else TextDecoration.None
                        )
                    ) {
                        appendInlineMarkdown(trimmed.drop(6), codeBg, codeFg)
                    }
                }
                trimmed.startsWith("- ") || trimmed.startsWith("* ") -> {
                    if (indentStr.isNotEmpty()) textBuilder.append(indentStr)
                    textBuilder.withStyle(SpanStyle(color = secondary, fontWeight = FontWeight.Bold)) {
                        append("$bulletGlyph ")
                    }
                    textBuilder.withStyle(SpanStyle(color = primary)) {
                        appendInlineMarkdown(trimmed.drop(2), codeBg, codeFg)
                    }
                }
                trimmed.startsWith("> ") -> {
                    if (indentStr.isNotEmpty()) textBuilder.append(indentStr)
                    textBuilder.withStyle(SpanStyle(color = accent.copy(alpha = 0.8f), fontWeight = FontWeight.SemiBold)) {
                        append("▎ ")
                    }
                    textBuilder.withStyle(SpanStyle(color = secondary)) {
                        appendInlineMarkdown(trimmed.drop(2), codeBg, codeFg)
                    }
                }
                else -> {
                    val orderedMatch = mobileOrderedListRegex.matchEntire(trimmed)
                    if (orderedMatch != null) {
                        if (indentStr.isNotEmpty()) textBuilder.append(indentStr)
                        textBuilder.withStyle(SpanStyle(color = secondary)) {
                            append("${orderedMatch.groupValues[1]}. ")
                        }
                        textBuilder.withStyle(SpanStyle(color = primary)) {
                            appendInlineMarkdown(orderedMatch.groupValues[2], codeBg, codeFg)
                        }
                    } else {
                        if (indentStr.isNotEmpty()) textBuilder.append(indentStr)
                        textBuilder.withStyle(SpanStyle(color = primary)) {
                            appendInlineMarkdown(trimmed, codeBg, codeFg)
                        }
                    }
                }
            }
        }
        if (inCode && codeBuf.isNotEmpty()) {
            out.add(MobileMdChunk.CodeBlock(codeLang, codeBuf.joinToString("\n")))
        } else {
            flushText()
        }
        return out
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FlomoMobileNoteCard(
    note: WhimNote,
    modifier: Modifier = Modifier,
    onTapTag: (String) -> Unit,
    onTapImage: (String) -> Unit,
    onEdit: () -> Unit,
    onTogglePin: () -> Unit,
    onToggleArchive: () -> Unit,
    onCopy: () -> Unit,
    onDelete: () -> Unit
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    var menuExpanded by remember { mutableStateOf(false) }
    var textExpanded by remember(note.id) { mutableStateOf(false) }
    var contentOverflow by remember(note.id, note.updatedAt) { mutableStateOf(false) }
    val maxCollapsedPx = with(LocalDensity.current) { 340.dp.roundToPx() }

    val parsed = remember(note.id, note.updatedAt, c.textPrimary) {
        MobileCardParseCache.getOrParse(
            note = note,
            primary = c.textPrimary,
            secondary = c.textSecondary,
            muted = c.textMuted,
            accent = c.accent,
            codeBg = c.tagBg,
            codeFg = c.tagText
        )
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(c.card)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = if (note.pinned) "置顶 · ${parsed.timeStr}" else parsed.timeStr,
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
                        text = { Text("编辑") },
                        onClick = { menuExpanded = false; onEdit() }
                    )
                    DropdownMenuItem(
                        text = { Text(if (note.pinned) "取消置顶" else "置顶") },
                        onClick = { menuExpanded = false; onTogglePin() }
                    )
                    DropdownMenuItem(
                        text = { Text(if (note.archived) "取消归档" else "归档") },
                        onClick = { menuExpanded = false; onToggleArchive() }
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

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clipToBounds()
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .layout { measurable, constraints ->
                        val placeable = measurable.measure(constraints.copy(maxHeight = Constraints.Infinity))
                        val overflows = placeable.height > maxCollapsedPx + 24
                        if (contentOverflow != overflows) {
                            contentOverflow = overflows
                        }
                        val h = if (!textExpanded && overflows) maxCollapsedPx else placeable.height
                        layout(placeable.width, h) {
                            placeable.placeRelative(0, 0)
                        }
                    },
                verticalArrangement = Arrangement.spacedBy(9.dp)
            ) {
                parsed.blocks.forEach { block ->
                    when (block) {
                        is MobileCardBlock.TextBlock -> MobileMarkdownChunksView(chunks = block.chunks)
                        is MobileCardBlock.ImageBlock -> {
                            val ratio = remember(block.path) { MobileImageBoundsCache.aspectRatio(block.path) }
                            val req = remember(block.path) {
                                ImageRequest.Builder(context)
                                    .data(File(block.path))
                                    .size(960, 960)
                                    .precision(Precision.INEXACT)
                                    .crossfade(160)
                                    .build()
                            }
                            AsyncImage(
                                model = req,
                                contentDescription = "内联图片",
                                contentScale = ContentScale.Fit,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .heightIn(max = 280.dp)
                                    .aspectRatio(ratio)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(c.canvas)
                                    .clickable { onTapImage(block.path) }
                            )
                        }
                    }
                }

                if (parsed.trailing.isNotEmpty()) {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(parsed.trailing, key = { it.sha256 }) { att ->
                            val req = remember(att.localPath) {
                                ImageRequest.Builder(context)
                                    .data(File(att.localPath))
                                    .size(320, 320)
                                    .precision(Precision.INEXACT)
                                    .crossfade(160)
                                    .build()
                            }
                            AsyncImage(
                                model = req,
                                contentDescription = "图片附件",
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .size(104.dp)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(c.canvas)
                                    .clickable { onTapImage(att.localPath) }
                            )
                        }
                    }
                }
            }

            if (contentOverflow && !textExpanded) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .height(52.dp)
                        .background(
                            Brush.verticalGradient(
                                colors = listOf(Color.Transparent, c.card)
                            )
                        )
                )
            }
        }

        if (contentOverflow) {
            Text(
                text = if (textExpanded) "收起" else "展开全文",
                style = t.meta,
                fontWeight = FontWeight.Medium,
                color = c.tagText,
                modifier = Modifier.clickable { textExpanded = !textExpanded }
            )
        }
    }
}

@Composable
private fun MobileCardDeck(
    notes: List<WhimNote>,
    isRandomMode: Boolean,
    resetKey: String,
    onTapImage: (String) -> Unit,
    onEdit: (WhimNote) -> Unit,
    onTogglePin: (WhimNote) -> Unit,
    onToggleArchive: (WhimNote) -> Unit,
    onCopy: (WhimNote) -> Unit,
    onDelete: (WhimNote) -> Unit,
    onReshuffle: () -> Unit,
    modifier: Modifier = Modifier
) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val swipeThresholdPx = with(density) { 96.dp.toPx() }
    val flyOutPx = with(density) { 460.dp.toPx() }

    var currentIndex by remember(resetKey) { mutableStateOf(0) }
    val dragX = remember(resetKey) { Animatable(0f) }
    var isAnimatingOut by remember(resetKey) { mutableStateOf(false) }

    fun swipeNext(direction: Float = -1f) {
        if (isAnimatingOut || currentIndex >= notes.size) return
        isAnimatingOut = true
        scope.launch {
            dragX.animateTo(direction * flyOutPx, tween(190))
            currentIndex += 1
            dragX.snapTo(0f)
            isAnimatingOut = false
        }
    }

    fun goPrev() {
        if (isAnimatingOut || currentIndex <= 0) return
        scope.launch {
            dragX.snapTo(0f)
            currentIndex -= 1
        }
    }

    Column(
        modifier = modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 92.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        if (notes.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    if (isRandomMode) "暂无可随机漫步的历史笔记" else "这一天还没有记录笔记",
                    style = t.body,
                    color = c.textMuted
                )
            }
        } else if (currentIndex >= notes.size) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(c.card)
                        .border(0.8.dp, c.border, RoundedCornerShape(14.dp))
                        .padding(horizontal = 24.dp, vertical = 30.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    Text(
                        if (isRandomMode) "本批 ${notes.size} 条灵感已漫步完毕" else "今日 ${notes.size} 条记录已全部回顾",
                        style = t.section,
                        color = c.textPrimary
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .background(c.canvas)
                                .clickable { currentIndex = (notes.size - 1).coerceAtLeast(0) }
                                .padding(horizontal = 14.dp, vertical = 8.dp)
                        ) {
                            Text("回看上一张", style = t.meta, color = c.textSecondary)
                        }
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .background(c.accent)
                                .clickable {
                                    if (isRandomMode) {
                                        currentIndex = 0
                                        onReshuffle()
                                    } else {
                                        currentIndex = 0
                                    }
                                }
                                .padding(horizontal = 16.dp, vertical = 8.dp)
                        ) {
                            Text(
                                if (isRandomMode) "换一批" else "重新回顾",
                                style = t.meta,
                                color = Color.White,
                                fontWeight = FontWeight.Medium
                            )
                        }
                    }
                }
            }
        } else {
            val visibleEnd = minOf(notes.size, currentIndex + 3)
            val dragProgress = (abs(dragX.value) / (swipeThresholdPx * 1.4f)).coerceIn(0f, 1f)

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .padding(bottom = 22.dp)
            ) {
                for (idx in (visibleEnd - 1) downTo currentIndex) {
                    val depth = idx - currentIndex
                    val note = notes[idx]
                    val isTop = depth == 0
                    val scale = if (isTop) 1f else (1f - depth * 0.045f + dragProgress * 0.045f)
                    val offsetYDp = if (isTop) 0.dp else ((depth * 14f - dragProgress * 14f).dp)
                    val cardAlpha = if (isTop) 1f else (1f - depth * 0.22f + dragProgress * 0.22f).coerceIn(0.45f, 1f)
                    val parsed = remember(note.id, note.updatedAt, c.textPrimary) {
                        MobileCardParseCache.getOrParse(
                            note = note,
                            primary = c.textPrimary,
                            secondary = c.textSecondary,
                            muted = c.textMuted,
                            accent = c.accent,
                            codeBg = c.tagBg,
                            codeFg = c.tagText
                        )
                    }
                    var menuExpanded by remember(note.id) { mutableStateOf(false) }

                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .graphicsLayer {
                                scaleX = scale
                                scaleY = scale
                                translationX = if (isTop) dragX.value else 0f
                                translationY = with(density) { offsetYDp.toPx() }
                                rotationZ = if (isTop) (dragX.value / 34f).coerceIn(-12f, 12f) else 0f
                                alpha = cardAlpha
                            }
                            .clip(RoundedCornerShape(14.dp))
                            .background(c.card)
                            .border(0.8.dp, c.border, RoundedCornerShape(14.dp))
                            .then(
                                if (isTop) {
                                    Modifier.pointerInput(note.id, currentIndex) {
                                        detectHorizontalDragGestures(
                                            onHorizontalDrag = { _, dragAmount ->
                                                if (!isAnimatingOut) {
                                                    scope.launch { dragX.snapTo(dragX.value + dragAmount) }
                                                }
                                            },
                                            onDragEnd = {
                                                if (abs(dragX.value) > swipeThresholdPx) {
                                                    swipeNext(if (dragX.value >= 0f) 1f else -1f)
                                                } else {
                                                    scope.launch { dragX.animateTo(0f, tween(180)) }
                                                }
                                            },
                                            onDragCancel = {
                                                scope.launch { dragX.animateTo(0f, tween(180)) }
                                            }
                                        )
                                    }
                                } else {
                                    Modifier
                                }
                            )
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = if (note.pinned) "置顶 · ${parsed.timeStr}" else parsed.timeStr,
                                style = t.meta,
                                color = c.textSecondary
                            )
                            if (isTop) {
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
                                        DropdownMenuItem(text = { Text("编辑") }, onClick = { menuExpanded = false; onEdit(note) })
                                        DropdownMenuItem(text = { Text(if (note.pinned) "取消置顶" else "置顶") }, onClick = { menuExpanded = false; onTogglePin(note) })
                                        DropdownMenuItem(text = { Text(if (note.archived) "取消归档" else "归档") }, onClick = { menuExpanded = false; onToggleArchive(note) })
                                        DropdownMenuItem(text = { Text("复制内容") }, onClick = { menuExpanded = false; onCopy(note) })
                                        DropdownMenuItem(text = { Text("删除") }, onClick = { menuExpanded = false; onDelete(note) })
                                    }
                                }
                            }
                        }

                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f)
                                .verticalScroll(rememberScrollState()),
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            parsed.blocks.forEach { block ->
                                when (block) {
                                    is MobileCardBlock.TextBlock -> MobileMarkdownChunksView(chunks = block.chunks)
                                    is MobileCardBlock.ImageBlock -> {
                                        val ratio = remember(block.path) { MobileImageBoundsCache.aspectRatio(block.path) }
                                        val req = remember(block.path) {
                                            ImageRequest.Builder(context)
                                                .data(File(block.path))
                                                .size(960, 960)
                                                .precision(Precision.INEXACT)
                                                .crossfade(160)
                                                .build()
                                        }
                                        AsyncImage(
                                            model = req,
                                            contentDescription = "内联图片",
                                            contentScale = ContentScale.Fit,
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .heightIn(max = 280.dp)
                                                .aspectRatio(ratio)
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(c.canvas)
                                                .clickable { onTapImage(block.path) }
                                        )
                                    }
                                }
                            }
                            if (parsed.trailing.isNotEmpty()) {
                                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    items(parsed.trailing, key = { it.sha256 }) { att ->
                                        val req = remember(att.localPath) {
                                            ImageRequest.Builder(context)
                                                .data(File(att.localPath))
                                                .size(320, 320)
                                                .precision(Precision.INEXACT)
                                                .crossfade(160)
                                                .build()
                                        }
                                        AsyncImage(
                                            model = req,
                                            contentDescription = "图片附件",
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier
                                                .size(104.dp)
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(c.canvas)
                                                .clickable { onTapImage(att.localPath) }
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(c.card)
                        .clickable(enabled = currentIndex > 0) { goPrev() }
                        .padding(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Text("上一张", style = t.meta, color = if (currentIndex > 0) c.textPrimary else c.textMuted)
                }
                Text(
                    "${currentIndex + 1} / ${notes.size} · 左右滑动切卡",
                    style = t.meta,
                    color = c.textSecondary
                )
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(c.accent)
                        .clickable { swipeNext(-1f) }
                        .padding(horizontal = 14.dp, vertical = 8.dp)
                ) {
                    Text(
                        if (currentIndex + 1 >= notes.size) "完成" else "下一张",
                        style = t.meta,
                        color = Color.White,
                        fontWeight = FontWeight.Medium
                    )
                }
            }
        }
    }
}

@Composable
private fun MobileMarkdownChunksView(chunks: List<MobileMdChunk>) {
    val c = WhimTheme.colors
    val t = WhimTheme.typography

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        chunks.forEach { chunk ->
            when (chunk) {
                is MobileMdChunk.RichText -> {
                    Text(
                        text = chunk.text,
                        style = t.body,
                        color = c.textPrimary
                    )
                }
                is MobileMdChunk.CodeBlock -> {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(7.dp))
                            .background(c.canvas)
                            .border(0.8.dp, c.border, RoundedCornerShape(7.dp))
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        if (chunk.lang.isNotEmpty()) {
                            Text(chunk.lang, fontSize = 11.sp, fontFamily = FontFamily.Monospace, color = c.textMuted)
                        }
                        Text(
                            text = chunk.code,
                            fontSize = 12.5.sp,
                            fontFamily = FontFamily.Monospace,
                            color = c.textPrimary,
                            modifier = Modifier.horizontalScroll(rememberScrollState())
                        )
                    }
                }
            }
        }
    }
}

private fun AnnotatedString.Builder.appendPlainWithInlineTags(segment: String, tagBg: Color, tagFg: Color) {
    if ('#' !in segment) {
        append(segment)
        return
    }
    var idx = 0
    for (m in mobileTagStripRegex.findAll(segment)) {
        if (m.range.first > idx) append(segment.substring(idx, m.range.first))
        val lead = m.groupValues[1]
        val rawTag = m.groupValues[2]
        if (lead.isNotEmpty()) append(lead)
        val normalized = rawTag.split("/")
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString("/")
        if (normalized.isNotEmpty()) {
            withLink(
                LinkAnnotation.Clickable(
                    tag = "whim_tag_$normalized",
                    styles = TextLinkStyles(style = SpanStyle(color = tagFg, background = tagBg)),
                    linkInteractionListener = { MobileTagDispatch.onTap?.invoke(normalized) }
                )
            ) {
                append("#$rawTag")
            }
        } else {
            append("#$rawTag")
        }
        idx = m.range.last + 1
    }
    if (idx < segment.length) append(segment.substring(idx))
}

private fun AnnotatedString.Builder.appendInlineMarkdown(raw: String, codeBg: Color, codeFg: Color) {
    if ('*' !in raw && '~' !in raw && '`' !in raw) {
        appendPlainWithInlineTags(raw, codeBg, codeFg)
        return
    }
    var idx = 0
    for (m in inlineMdTokenRegex.findAll(raw)) {
        if (m.range.first > idx) appendPlainWithInlineTags(raw.substring(idx, m.range.first), codeBg, codeFg)
        val tok = m.value
        when {
            tok.startsWith("**") && tok.endsWith("**") -> withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { appendPlainWithInlineTags(tok.drop(2).dropLast(2), codeBg, codeFg) }
            tok.startsWith("~~") && tok.endsWith("~~") -> withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { appendPlainWithInlineTags(tok.drop(2).dropLast(2), codeBg, codeFg) }
            tok.startsWith("`") && tok.endsWith("`") -> withStyle(SpanStyle(background = codeBg, color = codeFg)) { append(" ${tok.drop(1).dropLast(1)} ") }
            tok.startsWith("*") && tok.endsWith("*") -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { appendPlainWithInlineTags(tok.drop(1).dropLast(1), codeBg, codeFg) }
            else -> appendPlainWithInlineTags(tok, codeBg, codeFg)
        }
        idx = m.range.last + 1
    }
    if (idx < raw.length) appendPlainWithInlineTags(raw.substring(idx), codeBg, codeFg)
}
