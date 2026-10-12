// RelayService.kt: optional foreground service (type connectedDevice) that keeps Libre's
// Bluetooth links and relay running while the app is in the background (issue #4). Our own code.
// Started only after the person turns on "Keep relaying in the background"; the notification says
// what it does and has a Stop action. Scan and advertise settings in the background come from
// PowerPolicy, so a hidden phone scans much less than an open one.
package app.libre.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat

class RelayService : Service() {
    companion object {
        private const val CHANNEL = "relay"
        private const val NOTIFICATION_ID = 7
        private const val ACTION_STOP = "app.libre.android.STOP_RELAY"

        fun start(ctx: Context) {
            try { ContextCompat.startForegroundService(ctx, Intent(ctx, RelayService::class.java)) }
            catch (e: IllegalStateException) { Log.w(BleTransport.TAG, "background relay not started: ${e.message}") }
        }

        fun stop(ctx: Context) { ctx.stopService(Intent(ctx, RelayService::class.java)) }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = application as LibreApp
        if (intent?.action == ACTION_STOP) {
            app.setBackgroundRelay(false)
            return START_NOT_STICKY
        }
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            else startForeground(NOTIFICATION_ID, notification())
        } catch (e: RuntimeException) {
            // Android refused (for example a restart from the background on Android 12+, or the
            // Nearby devices permission was taken away). Stay stopped; opening Libre starts it again.
            Log.w(BleTransport.TAG, "background relay refused: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        app.startBluetooth()
        return START_STICKY
    }

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Background relay", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while Libre keeps passing messages for nearby phones in the background."
            })
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), flags)
        val stop = PendingIntent.getService(this, 1, Intent(this, RelayService::class.java).setAction(ACTION_STOP), flags)
        val text = "Libre keeps passing messages for people nearby over Bluetooth. It scans less while the app is closed."
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("Libre is relaying nearby messages")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel), "Stop", stop).build())
            .build()
    }
}
