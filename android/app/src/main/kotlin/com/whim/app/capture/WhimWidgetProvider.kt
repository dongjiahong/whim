package com.whim.app.capture

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import com.whim.app.R
import com.whim.app.core.WhimCoreBridge

/**
 * Home Screen Widget: displays today's note count and opens QuickCaptureActivity in one tap.
 */
class WhimWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        WhimCoreBridge.ensureInit(context)
        val todayCount = runCatching { WhimCoreBridge.countTodayNotesBlocking() }.getOrDefault(0)
        for (id in appWidgetIds) {
            updateWidget(context, appWidgetManager, id, todayCount)
        }
    }

    companion object {
        fun refreshAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, WhimWidgetProvider::class.java))
            if (ids.isEmpty()) return
            WhimCoreBridge.ensureInit(context)
            val todayCount = runCatching { WhimCoreBridge.countTodayNotesBlocking() }.getOrDefault(0)
            for (id in ids) {
                updateWidget(context, mgr, id, todayCount)
            }
        }

        private fun updateWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int,
            todayCount: Int
        ) {
            val intent = Intent(context, QuickCaptureActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pi = PendingIntent.getActivity(
                context,
                3002,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val views = RemoteViews(context.packageName, R.layout.widget_whim).apply {
                setTextViewText(R.id.widget_subtitle, "今日已记 $todayCount 条")
                setOnClickPendingIntent(R.id.widget_root, pi)
                setOnClickPendingIntent(R.id.widget_action, pi)
            }
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
