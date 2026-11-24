package com.whim.app.review

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.Calendar
import java.util.Locale

data class ReviewSchedule(
    val enabled: Boolean = true,
    val hour: Int = 21,
    val minute: Int = 30,
    val weekdays: Set<Int> = ALL_WEEKDAYS,
    val skipIfEmpty: Boolean = false
) {
    companion object {
        val ALL_WEEKDAYS: Set<Int> = setOf(
            Calendar.SUNDAY,
            Calendar.MONDAY,
            Calendar.TUESDAY,
            Calendar.WEDNESDAY,
            Calendar.THURSDAY,
            Calendar.FRIDAY,
            Calendar.SATURDAY
        )
        val WORKDAYS: Set<Int> = setOf(
            Calendar.MONDAY,
            Calendar.TUESDAY,
            Calendar.WEDNESDAY,
            Calendar.THURSDAY,
            Calendar.FRIDAY
        )
        val WEEKENDS: Set<Int> = setOf(Calendar.SATURDAY, Calendar.SUNDAY)
    }
}

object DailyReviewScheduler {
    private const val PREFS = "whim_review_prefs"
    private const val KEY_HOUR = "review_hour"
    private const val KEY_MINUTE = "review_minute"
    private const val KEY_ENABLED = "review_enabled"
    private const val KEY_WEEKDAYS = "review_weekdays"
    private const val KEY_SKIP_IF_EMPTY = "review_skip_if_empty"

    const val ACTION_DAILY_REVIEW = "com.whim.app.ACTION_DAILY_REVIEW"
    const val ACTION_SNOOZE_REVIEW = "com.whim.app.ACTION_SNOOZE_REVIEW"
    const val EXTRA_IS_SNOOZE = "is_snooze"

    private const val REQ_DAILY = 2048
    private const val REQ_SNOOZE = 2050

    fun getSchedule(context: Context): ReviewSchedule {
        val sp = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val rawDays = sp.getString(KEY_WEEKDAYS, null)
        val parsedDays = rawDays
            ?.split(",")
            ?.mapNotNull { it.trim().toIntOrNull() }
            ?.filter { it in Calendar.SUNDAY..Calendar.SATURDAY }
            ?.toSet()
            ?.takeIf { it.isNotEmpty() }
            ?: ReviewSchedule.ALL_WEEKDAYS
        return ReviewSchedule(
            enabled = sp.getBoolean(KEY_ENABLED, true),
            hour = sp.getInt(KEY_HOUR, 21).coerceIn(0, 23),
            minute = sp.getInt(KEY_MINUTE, 30).coerceIn(0, 59),
            weekdays = parsedDays,
            skipIfEmpty = sp.getBoolean(KEY_SKIP_IF_EMPTY, false)
        )
    }

    fun updateSchedule(
        context: Context,
        enabled: Boolean,
        hour: Int,
        minute: Int,
        weekdays: Set<Int> = ReviewSchedule.ALL_WEEKDAYS,
        skipIfEmpty: Boolean = false
    ): ReviewSchedule {
        val safeDays = weekdays.filter { it in Calendar.SUNDAY..Calendar.SATURDAY }.toSet()
            .ifEmpty { ReviewSchedule.ALL_WEEKDAYS }
        val updated = ReviewSchedule(
            enabled = enabled,
            hour = hour.coerceIn(0, 23),
            minute = minute.coerceIn(0, 59),
            weekdays = safeDays,
            skipIfEmpty = skipIfEmpty
        )
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_ENABLED, updated.enabled)
            .putInt(KEY_HOUR, updated.hour)
            .putInt(KEY_MINUTE, updated.minute)
            .putString(KEY_WEEKDAYS, updated.weekdays.sorted().joinToString(","))
            .putBoolean(KEY_SKIP_IF_EMPTY, updated.skipIfEmpty)
            .apply()
        if (updated.enabled) {
            scheduleNext(context)
        } else {
            cancel(context)
        }
        return updated
    }

    fun canScheduleExactAlarms(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return am.canScheduleExactAlarms()
    }

    fun scheduleNext(context: Context) {
        val schedule = getSchedule(context)
        if (!schedule.enabled || schedule.weekdays.isEmpty()) {
            cancel(context)
            return
        }

        val now = System.currentTimeMillis()
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, schedule.hour)
            set(Calendar.MINUTE, schedule.minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= now) {
                add(Calendar.DAY_OF_YEAR, 1)
            }
            var guard = 0
            while (get(Calendar.DAY_OF_WEEK) !in schedule.weekdays && guard < 7) {
                add(Calendar.DAY_OF_YEAR, 1)
                guard++
            }
        }

        scheduleAt(context, cal.timeInMillis, dailyPendingIntent(context))
    }

    fun scheduleSnooze(context: Context, minutes: Int = 30) {
        val triggerAt = System.currentTimeMillis() + minutes.coerceAtLeast(1) * 60_000L
        scheduleAt(context, triggerAt, snoozeFirePendingIntent(context))
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(dailyPendingIntent(context))
        am.cancel(snoozeFirePendingIntent(context))
    }

    fun formatSummary(schedule: ReviewSchedule): String {
        if (!schedule.enabled || schedule.weekdays.isEmpty()) return "提醒已关"
        val timeStr = String.format(Locale.getDefault(), "%02d:%02d", schedule.hour, schedule.minute)
        return when (schedule.weekdays) {
            ReviewSchedule.ALL_WEEKDAYS -> "每天 $timeStr"
            ReviewSchedule.WORKDAYS -> "工作日 $timeStr"
            ReviewSchedule.WEEKENDS -> "周末 $timeStr"
            else -> {
                val labels = listOf(
                    Calendar.MONDAY to "一",
                    Calendar.TUESDAY to "二",
                    Calendar.WEDNESDAY to "三",
                    Calendar.THURSDAY to "四",
                    Calendar.FRIDAY to "五",
                    Calendar.SATURDAY to "六",
                    Calendar.SUNDAY to "日"
                )
                val picked = labels.filter { it.first in schedule.weekdays }.joinToString("、") { it.second }
                "周$picked $timeStr"
            }
        }
    }

    private fun scheduleAt(context: Context, triggerAtMs: Long, pi: PendingIntent) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !am.canScheduleExactAlarms()) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMs, pi)
            return
        }
        // Use setAlarmClock so Doze mode, App Standby Buckets, and OEM ROM background freezes
        // never batch or defer the reminder until the user manually reopens the app.
        val showIntent = Intent(context, com.whim.app.MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(com.whim.app.MainActivity.EXTRA_OPEN_REVIEW, true)
        }
        val showPi = PendingIntent.getActivity(
            context,
            REQ_DAILY + 1,
            showIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        am.setAlarmClock(AlarmManager.AlarmClockInfo(triggerAtMs, showPi), pi)
    }

    private fun dailyPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, DailyReviewReceiver::class.java).apply {
            action = ACTION_DAILY_REVIEW
        }
        return PendingIntent.getBroadcast(
            context,
            REQ_DAILY,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun snoozeFirePendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, DailyReviewReceiver::class.java).apply {
            action = ACTION_DAILY_REVIEW
            putExtra(EXTRA_IS_SNOOZE, true)
        }
        return PendingIntent.getBroadcast(
            context,
            REQ_SNOOZE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
