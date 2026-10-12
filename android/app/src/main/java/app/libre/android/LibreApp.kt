// LibreApp.kt: one MeshController and one Bluetooth link for the whole app. Every call into the
// controller runs on one background thread, so the relay and timelines are never touched twice at once.
// It also watches whether Libre is on screen, the screen and the battery, and picks the Bluetooth
// power profile from them (PowerPolicy), and holds the "Keep relaying in the background" choice.
package app.libre.android

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import app.libre.core.PowerPolicy
import android.util.Log
import app.libre.mesh.MeshController
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class LibreApp : Application() {
    lateinit var mesh: MeshController
        private set
    private val worker = Executors.newSingleThreadScheduledExecutor { Thread(it, "libre-mesh") }
    private var ble: BleTransport? = null

    private val prefs by lazy { getSharedPreferences("libre", Context.MODE_PRIVATE) }
    private val _backgroundRelay = MutableStateFlow(false)
    /** The person chose to keep relaying while Libre is closed (RelayService). Off by default. */
    val backgroundRelay: StateFlow<Boolean> = _backgroundRelay
    private val _power = MutableStateFlow(PowerPolicy.FOREGROUND)
    val power: StateFlow<PowerPolicy.Profile> = _power

    private var startedActivities = 0
    private var screenOn = true
    private var batteryPct: Int? = null
    private var charging = false

    override fun onCreate() {
        super.onCreate()
        mesh = MeshController(filesDir.resolve("libre"))
        mesh.timingLog = { Log.i("LibreMesh", it) }
        worker.scheduleWithFixedDelay({ runCatching { mesh.tick() } }, 5, 5, TimeUnit.SECONDS)
        // Relay jitter (RelayScheduler): relays wait a few ms on the mesh thread.
        mesh.postDelayed = { ms, block -> worker.schedule({ runCatching { block() } }, ms, TimeUnit.MILLISECONDS) }

        _backgroundRelay.value = prefs.getBoolean("backgroundRelay", false)
        screenOn = getSystemService(PowerManager::class.java)?.isInteractive ?: true
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityStarted(a: Activity) { startedActivities++; updatePower() }
            override fun onActivityStopped(a: Activity) { startedActivities = maxOf(0, startedActivities - 1); updatePower() }
            override fun onActivityCreated(a: Activity, b: Bundle?) {}
            override fun onActivityResumed(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })
        ContextCompat.registerReceiver(this, object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) { screenOn = i.action == Intent.ACTION_SCREEN_ON; updatePower() }
        }, IntentFilter().apply { addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SCREEN_OFF) }, ContextCompat.RECEIVER_NOT_EXPORTED)
        val battery = object : BroadcastReceiver() { override fun onReceive(c: Context, i: Intent) { readBattery(i); updatePower() } }
        ContextCompat.registerReceiver(this, battery, IntentFilter(Intent.ACTION_BATTERY_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
            ?.let { readBattery(it); updatePower() }
    }

    private fun readBattery(i: Intent) {
        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        batteryPct = if (level >= 0 && scale > 0) level * 100 / scale else null
        val status = i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
    }

    private fun updatePower() {
        val p = PowerPolicy.choose(PowerPolicy.State(startedActivities > 0, screenOn, batteryPct, charging))
        _power.value = p
        ble?.setPower(p)
    }

    fun run(block: (MeshController) -> Unit) { worker.execute { runCatching { block(mesh) } } }

    /** Starts Bluetooth once onboarding is done and permissions are granted. */
    fun startBluetooth() {
        if (ble != null || !mesh.profile.value.onboarded) return
        val t = BleTransport(this, mesh.meshName(), mesh.identity, object : BleTransport.Events {
            override fun linked(name: String) = this@LibreApp.run { it.peerLinked(name) }
            override fun unlinked(name: String) = this@LibreApp.run { it.peerUnlinked(name) }
            override fun received(data: ByteArray, from: String) = this@LibreApp.run { it.receive(data, from) }
            override fun problem(text: String) = this@LibreApp.run { it.problem(text) }
        })
        ble = t
        mesh.link = t
        t.setPower(_power.value)
        t.start()
    }

    /** Turns the background relay on or off (and remembers the choice). */
    fun setBackgroundRelay(on: Boolean) {
        prefs.edit { putBoolean("backgroundRelay", on) }
        _backgroundRelay.value = on
        if (on) RelayService.start(this) else RelayService.stop(this)
    }

    val bluetoothState: String get() = ble?.radioState ?: "not started"
    val framesSent: Int get() = ble?.framesSent ?: 0

    fun completeOnboarding(name: String) = this@LibreApp.run { it.completeOnboarding(name, Build.MODEL ?: "Android") }
}
