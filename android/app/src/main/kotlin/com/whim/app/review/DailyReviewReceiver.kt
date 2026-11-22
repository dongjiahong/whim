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
 * posts a system notification deep-linking to Daily Review, and schedules tomorrow's alarm.
 */
class DailyReviewReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            DailyReviewScheduler.scheduleNext(context)
            return
        }

        WhimCoreBridge.ensureInit(context)
        val todayCount = runCatching { WhimCoreBridge.countTodayNotesBlocking() }.getOrDefault(0)
        postNotification(context, todayCount)
        DailyReviewScheduler.scheduleNext(context)
    }

    private fun postNotification(context: Context, count: Int) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "whim_daily_review"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "每日复盘提醒",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "每晚提醒复盘当天记录的闪念"
            }
            nm.createNotificationChannel(channel)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(MainActivity.EXTRA_OPEN_REVIEW, true)
        }
        val pi = PendingIntent.getActivity(
            context,
            2049,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val body = if (count > 0) {
            "今天记录了 $count 条闪念，花 2 分钟整理和回顾一下。"
        } else {
            "今天还没有记录闪念，睡前记下脑海里的一个想法吧。"
        }

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_menu_edit)
            .setContentTitle("晚间复盘 · Whim")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build()

        NotificationManagerCompat.from(context).notify(2049, notification)
    }
}
