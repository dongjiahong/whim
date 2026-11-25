package com.whim.app.review

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale
import java.util.UUID

data class ReviewReminder(
    val id: String = UUID.randomUUID().toString(),
    val label: String = "",
    val hour: Int = 21,
    val minute: Int = 30,
    val weekdays: Set<Int> = ALL_WEEKDAYS,
    val enabled: Boolean = true,
    val skipIfEmpty: Boolean = false
) {
    fun formattedTime(): String =
        String.format(Locale.getDefault(), "%02d:%02d", hour, minute)

    fun totalMinutes(): Int = hour * 60 + minute

    fun displayTitle(): String {
        val trimmed = label.trim()
        if (trimmed.isNotEmpty()) return trimmed
        return when (hour) {
            in 5..11 -> "晨间复盘"
            in 12..17 -> "午后回顾"
            else -> "晚间总结"
        }
    }

    fun repeatSummary(): String = when (weekdays) {
        ALL_WEEKDAYS -> "每天"
        WORKDAYS -> "工作日"
        WEEKENDS -> "周末"
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
            val picked = labels.filter { it.first in weekdays }.joinToString("、") { it.second }
            if (picked.isEmpty()) "不重复" else "周$picked"
        }
    }

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
    private const val KEY_REMINDERS_JSON = "review_reminders_v2"

    // Legacy single-reminder keys for automatic one-time migration
    private const val LEGACY_KEY_HOUR = "review_hour"
    private const val LEGACY_KEY_MINUTE = "review_minute"
    private const val LEGACY_KEY_ENABLED = "review_enabled"
    private const val LEGACY_KEY_WEEKDAYS = "review_weekdays"
    private const val LEGACY_KEY_SKIP_IF_EMPTY = "review_skip_if_empty"

    const val ACTION_DAILY_REVIEW = "com.whim.app.ACTION_DAILY_REVIEW"
    const val ACTION_SNOOZE_REVIEW = "com.whim.app.ACTION_SNOOZE_REVIEW"
    const val EXTRA_IS_SNOOZE = "is_snooze"
    const val EXTRA_REMINDER_ID = "reminder_id"
    const val EXTRA_REMINDER_LABEL = "reminder_label"
    const val EXTRA_REMINDER_HOUR = "reminder_hour"
    const val EXTRA_SKIP_IF_EMPTY = "skip_if_empty"

    private const val REQ_DAILY = 2048
    private const val REQ_SNOOZE = 2050

    fun getReminders(context: Context): List<ReviewReminder> {
        val sp = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = sp.getString(KEY_REMINDERS_JSON, null)
        if (raw != null) {
            return parseJson(raw).sortedBy { it.totalMinutes() }
        }

        // One-time migration from legacy single-reminder preferences
        val legacyDays = sp.getString(LEGACY_KEY_WEEKDAYS, null)
            ?.split(",")
            ?.mapNotNull { it.trim().toIntOrNull() }
            ?.filter { it in Calendar.SUNDAY..Calendar.SATURDAY }
            ?.toSet()
            ?.takeIf { it.isNotEmpty() }
            ?: ReviewReminder.ALL_WEEKDAYS
        val legacyHour = sp.getInt(LEGACY_KEY_HOUR, 21).coerceIn(0, 23)
        val legacyMinute = sp.getInt(LEGACY_KEY_MINUTE, 30).coerceIn(0, 59)
        val migrated = ReviewReminder(
            label = if (legacyHour in 5..11) "晨间复盘" else "晚间总结",
            hour = legacyHour,
            minute = legacyMinute,
            weekdays = legacyDays,
            enabled = sp.getBoolean(LEGACY_KEY_ENABLED, true),
            skipIfEmpty = sp.getBoolean(LEGACY_KEY_SKIP_IF_EMPTY, false)
        )
        return saveReminders(context, listOf(migrated))
    }

    fun saveReminders(context: Context, reminders: List<ReviewReminder>): List<ReviewReminder> {
        val sanitized = reminders.map { r ->
            r.copy(
                hour = r.hour.coerceIn(0, 23),
                minute = r.minute.coerceIn(0, 59),
                weekdays = r.weekdays.filter { it in Calendar.SUNDAY..Calendar.SATURDAY }
                    .toSet()
                    .ifEmpty { ReviewReminder.ALL_WEEKDAYS }
            )
        }.sortedBy { it.totalMinutes() }

        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_REMINDERS_JSON, encodeJson(sanitized))
            .apply()

        scheduleNext(context)
        return sanitized
    }

    fun addReminder(context: Context, reminder: ReviewReminder): List<ReviewReminder> {
        val current = getReminders(context).toMutableList()
        current.add(reminder)
        return saveReminders(context, current)
    }

    fun updateReminder(context: Context, updated: ReviewReminder): List<ReviewReminder> {
        val current = getReminders(context).map { if (it.id == updated.id) updated else it }
        return saveReminders(context, current)
    }

    fun toggleReminder(context: Context, id: String): List<ReviewReminder> {
        val current = getReminders(context).map { if (it.id == id) it.copy(enabled = !it.enabled) else it }
        return saveReminders(context, current)
    }

    fun deleteReminder(context: Context, id: String): List<ReviewReminder> {
        val current = getReminders(context).filterNot { it.id == id }
        return saveReminders(context, current)
    }

    fun hasEnabledReminders(reminders: List<ReviewReminder>): Boolean =
        reminders.any { it.enabled && it.weekdays.isNotEmpty() }

    fun canScheduleExactAlarms(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return am.canScheduleExactAlarms()
    }

    fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = context.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
            ?: return true
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    fun nextTriggerSummary(context: Context): String? {
        val active = getReminders(context).filter { it.enabled && it.weekdays.isNotEmpty() }
        if (active.isEmpty()) return null
        val now = System.currentTimeMillis()
        var earliestTime = Long.MAX_VALUE
        var earliestReminder: ReviewReminder? = null
        for (r in active) {
            val nextMs = computeNextTriggerMs(r, now)
            if (nextMs < earliestTime) {
                earliestTime = nextMs
                earliestReminder = r
            }
        }
        val target = earliestReminder ?: return null
        val nowCal = Calendar.getInstance().apply { timeInMillis = now }
        val nextCal = Calendar.getInstance().apply { timeInMillis = earliestTime }
        val dayPrefix = when {
            nowCal.get(Calendar.YEAR) == nextCal.get(Calendar.YEAR) &&
                nowCal.get(Calendar.DAY_OF_YEAR) == nextCal.get(Calendar.DAY_OF_YEAR) -> "今天"
            else -> {
                val tomorrow = Calendar.getInstance().apply {
                    timeInMillis = now
                    add(Calendar.DAY_OF_YEAR, 1)
                }
                if (tomorrow.get(Calendar.YEAR) == nextCal.get(Calendar.YEAR) &&
                    tomorrow.get(Calendar.DAY_OF_YEAR) == nextCal.get(Calendar.DAY_OF_YEAR)
                ) "明天"
                else String.format(
                    Locale.getDefault(),
                    "%d/%d",
                    nextCal.get(Calendar.MONTH) + 1,
                    nextCal.get(Calendar.DAY_OF_MONTH)
                )
            }
        }
        return "下次提醒：$dayPrefix ${target.formattedTime()}（${target.displayTitle()}）"
    }

    fun scheduleNext(context: Context) {
        val active = getReminders(context).filter { it.enabled && it.weekdays.isNotEmpty() }
        if (active.isEmpty()) {
            cancel(context)
            return
        }

        val now = System.currentTimeMillis()
        var earliestTime = Long.MAX_VALUE
        var earliestReminder: ReviewReminder? = null

        for (r in active) {
            val nextMs = computeNextTriggerMs(r, now)
            if (nextMs < earliestTime) {
                earliestTime = nextMs
                earliestReminder = r
            }
        }

        val target = earliestReminder ?: return
        scheduleAt(context, earliestTime, dailyPendingIntent(context, target))
    }

    private fun computeNextTriggerMs(reminder: ReviewReminder, nowMs: Long): Long {
        val cal = Calendar.getInstance().apply {
            timeInMillis = nowMs
            set(Calendar.HOUR_OF_DAY, reminder.hour)
            set(Calendar.MINUTE, reminder.minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            // Add a small 2s guard so an alarm firing slightly early doesn't re-trigger the same minute
            if (timeInMillis <= nowMs + 2_000L) {
                add(Calendar.DAY_OF_YEAR, 1)
            }
            var guard = 0
            while (get(Calendar.DAY_OF_WEEK) !in reminder.weekdays && guard < 7) {
                add(Calendar.DAY_OF_YEAR, 1)
                guard++
            }
        }
        return cal.timeInMillis
    }

    fun scheduleSnooze(context: Context, minutes: Int = 30, label: String = "每日复盘") {
        val triggerAt = System.currentTimeMillis() + minutes.coerceAtLeast(1) * 60_000L
        scheduleAt(context, triggerAt, snoozeFirePendingIntent(context, label))
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(dailyPendingIntent(context, null))
        am.cancel(snoozeFirePendingIntent(context, "每日复盘"))
    }

    fun formatSummary(reminders: List<ReviewReminder>): String {
        val active = reminders.filter { it.enabled && it.weekdays.isNotEmpty() }.sortedBy { it.totalMinutes() }
        if (active.isEmpty()) return "提醒已关"
        if (active.size == 1) {
            val r = active.first()
            return "${r.repeatSummary()} ${r.formattedTime()}"
        }
        if (active.size == 2) {
            return "${active[0].formattedTime()} · ${active[1].formattedTime()}"
        }
        return "${active[0].formattedTime()} 等 ${active.size} 个提醒"
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

    private fun dailyPendingIntent(context: Context, reminder: ReviewReminder?): PendingIntent {
        val intent = Intent(context, DailyReviewReceiver::class.java).apply {
            action = ACTION_DAILY_REVIEW
            if (reminder != null) {
                putExtra(EXTRA_REMINDER_ID, reminder.id)
                putExtra(EXTRA_REMINDER_LABEL, reminder.displayTitle())
                putExtra(EXTRA_REMINDER_HOUR, reminder.hour)
                putExtra(EXTRA_SKIP_IF_EMPTY, reminder.skipIfEmpty)
            }
        }
        return PendingIntent.getBroadcast(
            context,
            REQ_DAILY,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun snoozeFirePendingIntent(context: Context, label: String): PendingIntent {
        val intent = Intent(context, DailyReviewReceiver::class.java).apply {
            action = ACTION_DAILY_REVIEW
            putExtra(EXTRA_IS_SNOOZE, true)
            putExtra(EXTRA_REMINDER_LABEL, label)
        }
        return PendingIntent.getBroadcast(
            context,
            REQ_SNOOZE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun encodeJson(reminders: List<ReviewReminder>): String {
        val arr = JSONArray()
        for (r in reminders) {
            val obj = JSONObject()
            obj.put("id", r.id)
            obj.put("label", r.label)
            obj.put("hour", r.hour)
            obj.put("minute", r.minute)
            obj.put("enabled", r.enabled)
            obj.put("skipIfEmpty", r.skipIfEmpty)
            val daysArr = JSONArray()
            r.weekdays.sorted().forEach { daysArr.put(it) }
            obj.put("weekdays", daysArr)
            arr.put(obj)
        }
        return arr.toString()
    }

    private fun parseJson(raw: String): List<ReviewReminder> {
        return runCatching {
            val arr = JSONArray(raw)
            val list = mutableListOf<ReviewReminder>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val daysArr = obj.optJSONArray("weekdays")
                val days = mutableSetOf<Int>()
                if (daysArr != null) {
                    for (j in 0 until daysArr.length()) {
                        val d = daysArr.optInt(j, -1)
                        if (d in Calendar.SUNDAY..Calendar.SATURDAY) days.add(d)
                    }
                }
                list.add(
                    ReviewReminder(
                        id = obj.optString("id").ifBlank { UUID.randomUUID().toString() },
                        label = obj.optString("label", ""),
                        hour = obj.optInt("hour", 21).coerceIn(0, 23),
                        minute = obj.optInt("minute", 30).coerceIn(0, 59),
                        weekdays = days.ifEmpty { ReviewReminder.ALL_WEEKDAYS },
                        enabled = obj.optBoolean("enabled", true),
                        skipIfEmpty = obj.optBoolean("skipIfEmpty", false)
                    )
                )
            }
            list
        }.getOrDefault(emptyList())
    }
}
