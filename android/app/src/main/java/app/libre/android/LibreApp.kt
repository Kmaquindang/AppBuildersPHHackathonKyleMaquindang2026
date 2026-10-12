// LibreApp.kt: one MeshController and one Bluetooth link for the whole app. Every call into the
// controller runs on one background thread, so the relay and timelines are never touched twice at once.
package app.libre.android

import android.app.Application
import android.os.Build
import android.util.Log
import app.libre.mesh.MeshController
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class LibreApp : Application() {
    lateinit var mesh: MeshController
        private set
    private val worker = Executors.newSingleThreadScheduledExecutor { Thread(it, "libre-mesh") }
    private var ble: BleTransport? = null

    override fun onCreate() {
        super.onCreate()
        mesh = MeshController(filesDir.resolve("libre"))
        mesh.timingLog = { Log.i("LibreMesh", it) }
        worker.scheduleWithFixedDelay({ runCatching { mesh.tick() } }, 5, 5, TimeUnit.SECONDS)
        // Relay jitter (RelayScheduler): relays wait a few ms on the mesh thread.
        mesh.postDelayed = { ms, block -> worker.schedule({ runCatching { block() } }, ms, TimeUnit.MILLISECONDS) }
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
        t.start()
    }

    val bluetoothState: String get() = ble?.radioState ?: "not started"
    val framesSent: Int get() = ble?.framesSent ?: 0

    fun completeOnboarding(name: String) = this@LibreApp.run { it.completeOnboarding(name, Build.MODEL ?: "Android") }
}
