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

/**
 * Fires even when the app process has been killed, checks today's note count via Go SQLite,
 * posts a system notification deep-linking to Daily Review (with a 30-min snooze action),
 * and schedules the next matching alarm.
 */
class DailyReviewReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> {
                DailyReviewScheduler.scheduleNext(context)
                return
            }
            DailyReviewScheduler.ACTION_SNOOZE_REVIEW -> {
                NotificationManagerCompat.from(context).cancel(NOTIF_ID)
                DailyReviewScheduler.scheduleSnooze(context, minutes = 30)
                return
            }
        }

        val isSnooze = intent.getBooleanExtra(DailyReviewScheduler.EXTRA_IS_SNOOZE, false)
        WhimCoreBridge.ensureInit(context)
        val schedule = DailyReviewScheduler.getSchedule(context)
        val todayCount = runCatching { WhimCoreBridge.countTodayNotesBlocking() }.getOrDefault(0)

        if (!isSnooze && schedule.skipIfEmpty && todayCount == 0) {
            DailyReviewScheduler.scheduleNext(context)
            return
        }

        postNotification(context, todayCount, isTest = false, isSnooze = isSnooze)
        if (!isSnooze) {
            DailyReviewScheduler.scheduleNext(context)
        }
    }

    companion object {
        private const val CHANNEL_ID = "whim_daily_review"
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
            isTest: Boolean = false,
            isSnooze: Boolean = false
        ): Boolean {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "每日复盘提醒",
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "按设定时间与星期提醒复盘当天记录的闪念"
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
            }
            val snoozePi = PendingIntent.getBroadcast(
                context,
                REQ_SNOOZE_ACTION,
                snoozeIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val title = if (isTest) "晚间复盘 · Whim（测试）" else "晚间复盘 · Whim"
            val body = when {
                isSnooze && count > 0 -> "稍后提醒时间到了，今天共记录了 $count 条闪念，花 2 分钟回顾一下。"
                isSnooze -> "稍后提醒时间到了，睡前记下今天的一个想法吧。"
                count > 0 -> "今天记录了 $count 条闪念，花 2 分钟整理和回顾一下。"
                else -> "今天还没有记录闪念，睡前记下脑海里的一个想法吧。"
            }

            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_edit)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
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
