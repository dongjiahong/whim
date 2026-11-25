package com.whim.app

import android.app.Application
import android.content.Context
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.memory.MemoryCache
import com.whim.app.core.WhimCoreBridge
import com.whim.app.review.DailyReviewScheduler
import com.whim.app.sync.SyncWorker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class WhimApplication : Application(), ImageLoaderFactory {
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        WhimCoreBridge.ensureInit(this)
        SyncWorker.enqueuePeriodic(this)
        DailyReviewScheduler.scheduleNext(this)

        // Silent daily maintenance: WAL-safe SQLite snapshot + purge trash older than 30 days
        appScope.launch {
            val prefs = getSharedPreferences("whim_maintenance_prefs", Context.MODE_PRIVATE)
            val todayKey = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
            if (prefs.getString("last_daily_maint", null) != todayKey) {
                runCatching { WhimCoreBridge.backupDatabase(keepDays = 7) }
                runCatching { WhimCoreBridge.purgeOldDeleted(days = 30) }
                prefs.edit().putString("last_daily_maint", todayKey).apply()
            }
        }
    }

    override fun newImageLoader(): ImageLoader {
        return ImageLoader.Builder(this)
            .memoryCache {
                MemoryCache.Builder(this)
                    .maxSizePercent(0.25)
                    .build()
            }
            .allowHardware(true)
            .crossfade(160)
            .respectCacheHeaders(false)
            .build()
    }
}
