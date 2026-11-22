package com.whim.app.review

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.Calendar

object DailyReviewScheduler {
    private const val PREFS = "whim_review_prefs"
    private const val KEY_HOUR = "review_hour"
    private const val KEY_MINUTE = "review_minute"
    private const val KEY_ENABLED = "review_enabled"
    const val ACTION_DAILY_REVIEW = "com.whim.app.ACTION_DAILY_REVIEW"

    fun getSchedule(context: Context): Triple<Boolean, Int, Int> {
        val sp = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return Triple(
            sp.getBoolean(KEY_ENABLED, true),
            sp.getInt(KEY_HOUR, 21),
            sp.getInt(KEY_MINUTE, 30)
        )
    }

    fun updateSchedule(context: Context, enabled: Boolean, hour: Int, minute: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_ENABLED, enabled)
            .putInt(KEY_HOUR, hour.coerceIn(0, 23))
            .putInt(KEY_MINUTE, minute.coerceIn(0, 59))
            .apply()
        if (enabled) {
            scheduleNext(context)
        } else {
            cancel(context)
        }
    }

    fun scheduleNext(context: Context) {
        val (enabled, hour, minute) = getSchedule(context)
        if (!enabled) return

        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= System.currentTimeMillis()) {
                add(Calendar.DAY_OF_YEAR, 1)
            }
        }

        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pendingIntent(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !am.canScheduleExactAlarms()) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cal.timeInMillis, pi)
        } else {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cal.timeInMillis, pi)
        }
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pendingIntent(context))
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, DailyReviewReceiver::class.java).apply {
            action = ACTION_DAILY_REVIEW
        }
        return PendingIntent.getBroadcast(
            context,
            2048,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
