package com.whim.app.review

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.whim.app.MainActivity
import com.whim.app.core.WhimCoreBridge
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Fires even when the app process has been killed. Uses goAsync() so SQLite/Go initialization
 * never blocks the main broadcast thread, skips DB init entirely for morning reminders when
 * skipIfEmpty is false, posts the notification, and schedules the next upcoming alarm.
 */
class DailyReviewReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            android.app.AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> {
                DailyReviewScheduler.scheduleNext(context)
                return
            }
            DailyReviewScheduler.ACTION_SNOOZE_REVIEW -> {
                val label = intent.getStringExtra(DailyReviewScheduler.EXTRA_REMINDER_LABEL).orEmpty().ifBlank { "每日复盘" }
                NotificationManagerCompat.from(context).cancel(NOTIF_ID)
                DailyReviewScheduler.scheduleSnooze(context, minutes = 30, label = label)
                return
            }
        }

        val isSnooze = intent.getBooleanExtra(DailyReviewScheduler.EXTRA_IS_SNOOZE, false)
        val label = intent.getStringExtra(DailyReviewScheduler.EXTRA_REMINDER_LABEL).orEmpty().ifBlank { "每日复盘" }
        val hour = intent.getIntExtra(DailyReviewScheduler.EXTRA_REMINDER_HOUR, 21)
        val skipIfEmpty = intent.getBooleanExtra(DailyReviewScheduler.EXTRA_SKIP_IF_EMPTY, false)

        // Fast-path: morning reminders without skipIfEmpty don't need today's note count at all
        if (!isSnooze && !skipIfEmpty && hour in 5..11) {
            postNotification(
                context = context,
                count = 0,
                label = label,
                hour = hour,
                isTest = false,
                isSnooze = false
            )
            DailyReviewScheduler.scheduleNext(context)
            return
        }

        val pendingResult = goAsync()
        val appCtx = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            try {
                WhimCoreBridge.ensureInit(appCtx)
                val todayCount = runCatching { WhimCoreBridge.countTodayNotesBlocking() }.getOrDefault(0)

                if (!isSnooze && skipIfEmpty && todayCount == 0) {
                    DailyReviewScheduler.scheduleNext(appCtx)
                    return@launch
                }

                postNotification(
                    context = appCtx,
                    count = todayCount,
                    label = label,
                    hour = hour,
                    isTest = false,
                    isSnooze = isSnooze
                )
                if (!isSnooze) {
                    DailyReviewScheduler.scheduleNext(appCtx)
                }
            } finally {
                pendingResult.finish()
            }
        }
    }

    companion object {
        private const val CHANNEL_ID = "whim_daily_review_v2"
        private const val NOTIF_ID = 2049
        private const val REQ_OPEN = 2049
        private const val REQ_SNOOZE_ACTION = 2051

        fun hasNotificationPermission(context: Context): Boolean {
            return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        }

        fun postNotification(
            context: Context,
            count: Int,
            label: String = "每日复盘",
            hour: Int = 21,
            isTest: Boolean = false,
            isSnooze: Boolean = false
        ): Boolean {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "每日复盘提醒",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "按设定时间与星期准时弹出复盘提醒"
                    enableVibration(true)
                }
                nm.createNotificationChannel(channel)
            }

            if (!hasNotificationPermission(context)) {
                return false
            }

            val openIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(MainActivity.EXTRA_OPEN_REVIEW, true)
            }
            val openPi = PendingIntent.getActivity(
                context,
                REQ_OPEN,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val snoozeIntent = Intent(context, DailyReviewReceiver::class.java).apply {
                action = DailyReviewScheduler.ACTION_SNOOZE_REVIEW
                putExtra(DailyReviewScheduler.EXTRA_REMINDER_LABEL, label)
            }
            val snoozePi = PendingIntent.getBroadcast(
                context,
                REQ_SNOOZE_ACTION,
                snoozeIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val safeLabel = label.ifBlank { "每日复盘" }
            val title = if (isTest) "$safeLabel · Whim（测试）" else "$safeLabel · Whim"
            val body = when {
                isSnooze && count > 0 -> "稍后提醒时间到了，今天共记录了 $count 条闪念，花 2 分钟回顾一下。"
                isSnooze -> "稍后提醒时间到了，花 2 分钟回顾一下最近的闪念吧。"
                hour in 5..11 -> "早安，花 2 分钟回顾一下昨日的闪念与思考，带着清晰开始今天。"
                hour in 12..17 && count > 0 -> "今天已记录 $count 条闪念，小憩片刻理顺一下思路吧。"
                hour in 12..17 -> "午后小憩，翻看最近的闪念，捕捉新的灵感。"
                count > 0 -> "今天记录了 $count 条闪念，花 2 分钟整理和回顾一下。"
                else -> "今天还没有记录闪念，睡前记下脑海里的一个想法吧。"
            }

            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_edit)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setAutoCancel(true)
                .setContentIntent(openPi)
                .addAction(0, "去复盘", openPi)
                .addAction(0, "30 分钟后再提醒", snoozePi)
                .build()

            NotificationManagerCompat.from(context).notify(NOTIF_ID, notification)
            return true
        }
    }
}
