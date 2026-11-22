package com.whim.app.sync

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.whim.app.capture.WhimWidgetProvider
import com.whim.app.core.WhimCoreBridge
import java.util.concurrent.TimeUnit

/**
 * Background peer-to-peer LAN sync worker driven by Android WorkManager.
 * Solves the foreground-only limitation without needing a battery-draining daemon.
 */
class SyncWorker(
    appContext: Context,
    params: WorkerParameters
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        WhimCoreBridge.ensureInit(applicationContext)
        val summary = WhimCoreBridge.syncOnceBlocking(timeoutSec = 8)
        if (summary.notesMerged > 0) {
            WhimWidgetProvider.refreshAll(applicationContext)
        }
        return Result.success()
    }

    companion object {
        private const val PERIODIC_WORK_NAME = "whim_lan_periodic_sync"
        private const val IMMEDIATE_WORK_NAME = "whim_lan_immediate_sync"

        private fun wifiConstraints(): Constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.UNMETERED)
            .build()

        fun enqueuePeriodic(context: Context) {
            val req = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(wifiConstraints())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                PERIODIC_WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                req
            )
        }

        fun enqueueImmediate(context: Context) {
            val req = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(wifiConstraints())
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                IMMEDIATE_WORK_NAME,
                ExistingWorkPolicy.REPLACE,
                req
            )
        }
    }
}
