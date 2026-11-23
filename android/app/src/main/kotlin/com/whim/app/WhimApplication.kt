package com.whim.app

import android.app.Application
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.memory.MemoryCache
import com.whim.app.core.WhimCoreBridge
import com.whim.app.review.DailyReviewScheduler
import com.whim.app.sync.SyncWorker

class WhimApplication : Application(), ImageLoaderFactory {
    override fun onCreate() {
        super.onCreate()
        WhimCoreBridge.ensureInit(this)
        SyncWorker.enqueuePeriodic(this)
        DailyReviewScheduler.scheduleNext(this)
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
