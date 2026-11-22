package com.whim.app

import android.app.Application
import com.whim.app.core.WhimCoreBridge
import com.whim.app.review.DailyReviewScheduler
import com.whim.app.sync.SyncWorker

class WhimApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        WhimCoreBridge.ensureInit(this)
        SyncWorker.enqueuePeriodic(this)
        DailyReviewScheduler.scheduleNext(this)
    }
}
