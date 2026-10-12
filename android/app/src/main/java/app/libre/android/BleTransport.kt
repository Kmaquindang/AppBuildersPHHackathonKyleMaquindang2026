// BleTransport.kt: Libre's Bluetooth LE link on Android, wire compatible with BLETransport.swift
// (iPhone and Mac, commit c534465). Android cannot join Apple's MultipeerConnectivity, so this is
// its only link. Every phone does both jobs:
// - GATT server (peripheral): advertises the Libre service UUID with one characteristic
//   (write without response + notify, plus the standard CCCD so centrals can subscribe).
// - GATT client (central): scans for the service, connects, asks for MTU 517, subscribes, writes.
// After a link is ready each side sends a signed hello (key, challenge, mesh name) and answers the
// other side's challenge with a proof (BleHandshake.kt); only verified links carry data. Data frames carry the
// sealed MeshMessage bytes, cut to the link's MTU (BleChunker) and put back together per link
// (BleReassembler). Flow control: one write in flight per client link (next one after
// onCharacteristicWrite), one notification in flight on the server (next after onNotificationSent).
// Two links between the same pair: the device whose key sorts last drops the one it opened.
// Connects go through ConnectPolicy: at most 7 links, signal floor, strongest first, one connect
// at a time, 10 s timeout, backoff, and quick retries for GATT status 133. A peer is its key, not
// its MAC address: an iPhone that comes back on a new address replaces its old link.
// All Bluetooth state lives on one HandlerThread.
package app.libre.android

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelUuid
import android.util.Log
import app.libre.core.BleChunker
import app.libre.core.BleReassembler
import app.libre.core.ConnectPolicy
import app.libre.core.FrameType
import app.libre.core.BleHello
import app.libre.core.DeviceIdentity
import app.libre.core.PeerBook
import app.libre.mesh.Link
import java.util.UUID

@SuppressLint("MissingPermission")
class BleTransport(
    private val context: Context,
    private val displayName: String,
    identity: DeviceIdentity,
    private val events: Events,
) : Link {
    interface Events {
        fun linked(name: String)
        fun unlinked(name: String)
        fun received(data: ByteArray, from: String)
        fun problem(text: String)
    }

    companion object {
        val SERVICE: UUID = UUID.fromString("BAA354FA-5C3F-4FD8-A2FB-A2F30E6C73F2")
        val CHARACTERISTIC: UUID = UUID.fromString("05F51AD3-42F8-4ABD-A52C-BD6C6537FAF7")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val TAG = "LibreBLE"
        const val MAX_QUEUED_FRAMES = 6000
    }

    private enum class Role { CENTRAL, PERIPHERAL }

    private inner class LinkState(val key: String, val role: Role, val device: BluetoothDevice) {
        var gatt: BluetoothGatt? = null
        var remote: BluetoothGattCharacteristic? = null
        var name: String? = null
        var mtu = 20
        var ready = false
        val queue = ArrayDeque<ByteArray>()
        var inFlight = false
        var nextId = (Math.random() * 0xFFFFFFFFL).toLong()
    }

    private val thread = HandlerThread("libre-ble").also { it.start() }
    private val handler = Handler(thread.looper)
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? get() = manager?.adapter
    private var server: BluetoothGattServer? = null
    private var serverChar: BluetoothGattCharacteristic? = null
    private var notifyBusy = false
    private val links = HashMap<String, LinkState>()
    private val pending = HashSet<String>()
    private val dropped = HashMap<String, String>()   // central device address -> peer key id (tie-break)
    private val book = PeerBook(identity)
    private val policy = ConnectPolicy(ConnectPolicy.Config.ANDROID)
    private val heard = HashMap<String, BluetoothDevice>()   // address -> device waiting for a connect slot
    private val reassembler = BleReassembler()
    private val serverMtu = HashMap<String, Int>()   // MTU a central negotiated with our server, by address
    private var running = false

    // Read from other threads.
    @Volatile private var named: Map<String, List<String>> = emptyMap()
    @Volatile var radioState: String = "starting"
        private set
    @Volatile var framesSent = 0
        private set

    override val linkedPeers: Set<String> get() = named.filterValues { it.isNotEmpty() }.keys

    fun start() = handler.post {
        if (running) return@post
        val a = adapter
        if (a == null) { radioState = "unsupported"; events.problem("This phone has no Bluetooth LE."); return@post }
        if (!a.isEnabled) { radioState = "off"; events.problem("Bluetooth is off. Turn it on so Libre can reach nearby phones and Macs."); return@post }
        running = true
        radioState = "on"
        try {
            openServer()
            startScan()
        } catch (e: SecurityException) {
            running = false
            radioState = "unauthorized"
            events.problem("Libre needs the Nearby devices permission to use Bluetooth.")
        }
        handler.postDelayed(rescan, 25_000)
        handler.postDelayed(tick, 2_000)
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            for (addr in policy.timedOut()) links["c-$addr"]?.let { l ->
                Log.i(TAG, "connect timed out; backing off")
                try { l.gatt?.disconnect(); l.gatt?.close() } catch (e: SecurityException) { }
                links.remove(l.key); pending.remove(addr)
            }
            startConnects()
            handler.postDelayed(this, 2_000)
        }
    }

    fun stop() = handler.post {
        if (!running) return@post
        running = false
        handler.removeCallbacks(rescan)
        handler.removeCallbacks(tick)
        try {
            adapter?.bluetoothLeScanner?.stopScan(scanCallback)
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
            for (l in links.values) l.gatt?.close()
            server?.close()
        } catch (e: SecurityException) { }
        val names = links.values.mapNotNull { it.name }.toSet()
        links.clear(); pending.clear(); dropped.clear(); heard.clear(); book.reset(); policy.reset(); server = null
        named = emptyMap()
        names.forEach(events::unlinked)
    }

    private val rescan = object : Runnable {
        override fun run() {
            if (!running) return
            try {
                adapter?.bluetoothLeScanner?.stopScan(scanCallback)
                startScan()
            } catch (e: SecurityException) { }
            handler.postDelayed(this, 25_000)
        }
    }

    /** Blocking follows the device key: a blocked device's links close and stay refused. */
    fun setBlocked(names: Set<String>) = handler.post { for (k in book.setBlocked(names)) drop(k) }

    private fun drop(key: String) {
        val l = links[key] ?: return
        try { l.gatt?.disconnect(); l.gatt?.close() } catch (e: SecurityException) { }
        if (l.role == Role.PERIPHERAL) try { server?.cancelConnection(l.device) } catch (e: SecurityException) { }
        closed(key)
    }

    // MARK: Send

    override fun send(data: ByteArray, to: Set<String>): Set<String> {
        if (data.size > BleChunker.MAX_MESSAGE_BYTES) return emptySet()
        val snapshot = named
        val targets = to.filter { !snapshot[it].isNullOrEmpty() }.toSet()
        handler.post {
            for (name in targets) {
                val key = named[name]?.firstOrNull() ?: continue
                val l = links[key] ?: continue
                if (l.ready) enqueue(l, data, FrameType.DATA)
            }
        }
        return targets
    }

    private fun enqueue(l: LinkState, data: ByteArray, type: FrameType) {
        val id = l.nextId and 0xFFFFFFFFL
        l.nextId = (l.nextId + 1) and 0xFFFFFFFFL
        val frames = BleChunker.frames(data, id, l.mtu, type) ?: return
        if (l.queue.size + frames.size > MAX_QUEUED_FRAMES) { events.problem("Bluetooth link to ${l.name ?: "a device"} is busy."); return }
        l.queue.addAll(frames)
        pump(l)
    }

    @Suppress("DEPRECATION")
    private fun pump(l: LinkState) {
        try {
            when (l.role) {
                Role.CENTRAL -> {
                    if (l.inFlight) return
                    val g = l.gatt ?: return
                    val ch = l.remote ?: return
                    val f = l.queue.firstOrNull() ?: return
                    val ok = if (Build.VERSION.SDK_INT >= 33) {
                        g.writeCharacteristic(ch, f, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == BluetoothGatt.GATT_SUCCESS
                    } else {
                        ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                        ch.value = f
                        g.writeCharacteristic(ch)
                    }
                    if (ok) { l.queue.removeFirst(); l.inFlight = true; framesSent++ }
                    else handler.postDelayed({ pump(l) }, 20)
                }
                Role.PERIPHERAL -> {
                    if (notifyBusy) return
                    val s = server ?: return
                    val ch = serverChar ?: return
                    val f = l.queue.firstOrNull() ?: return
                    val ok = if (Build.VERSION.SDK_INT >= 33) {
                        s.notifyCharacteristicChanged(l.device, ch, false, f) == BluetoothGatt.GATT_SUCCESS
                    } else {
                        ch.value = f
                        s.notifyCharacteristicChanged(l.device, ch, false)
                    }
                    if (ok) { l.queue.removeFirst(); notifyBusy = true; framesSent++ }
                    else handler.postDelayed({ pump(l) }, 20)
                }
            }
        } catch (e: SecurityException) { }
    }

    private fun pumpPeripherals() { for (l in links.values) if (l.role == Role.PERIPHERAL && l.queue.isNotEmpty()) { pump(l); if (notifyBusy) return } }

    // MARK: Link life

    private fun ready(l: LinkState) {
        if (l.ready) return
        l.ready = true
        Log.i(TAG, "link open role=${l.role} mtu=${l.mtu}")
        val challenge = book.opened(l.key, if (l.role == Role.CENTRAL) PeerBook.Role.CENTRAL else PeerBook.Role.PERIPHERAL)
        val hello = BleHello.make(book.identity, displayName, challenge) ?: run { Log.w(TAG, "hello not made"); return }
        enqueue(l, hello, FrameType.HELLO)
    }

    private fun received(raw: ByteArray, l: LinkState) {
        val done = reassembler.add(raw, l.key) ?: return
        when (done.type) {
            FrameType.HELLO -> when (val r = book.opened(l.key, if (l.role == Role.CENTRAL) PeerBook.Role.CENTRAL else PeerBook.Role.PERIPHERAL)
                .let { book.receivedHello(done.data, l.key) }) {
                is PeerBook.HelloResult.SendProof -> enqueue(l, r.proof, FrameType.PROOF)
                is PeerBook.HelloResult.Rejected -> { Log.i(TAG, "hello refused: ${r.why}"); if (r.why != "second hello") drop(l.key) }
            }
            FrameType.PROOF -> when (val r = book.receivedProof(done.data, l.key)) {
                is PeerBook.ProofResult.Verified -> {
                    r.replaced?.let { old -> Log.i(TAG, "${r.name} came back on a new address; closing the old link"); drop(old) }
                    if (l.role == Role.CENTRAL) policy.verified(l.device.address)
                    verified(l, r)
                }
                is PeerBook.ProofResult.Rejected -> { Log.i(TAG, "proof refused: ${r.why}"); drop(l.key) }
            }
            FrameType.DATA -> if (book.isVerified(l.key)) l.name?.let { events.received(done.data, it) }
            FrameType.PROBE -> enqueue(l, "ok".toByteArray(), FrameType.PROBE_REPLY)
            FrameType.PROBE_REPLY -> {}
        }
    }

    private fun verified(l: LinkState, r: PeerBook.ProofResult.Verified) {
        val name = r.name
        l.name = name
        Log.i(TAG, "verified $name key=${r.keyId.take(8)} role=${l.role} mtu=${l.mtu}")
        val dropId = r.dropLink
        if (dropId != null) {
            val central = links.remove(dropId)
            if (central != null) {
                dropped[central.device.address] = r.keyId
                policy.exclude(central.device.address)
                reassembler.reset(dropId)
                try { central.gatt?.disconnect(); central.gatt?.close() } catch (e: SecurityException) { }
            }
        }
        named = named.toMutableMap().also { it[name] = book.linkIds(name) }
        if (dropId == l.key) return
        if (r.newPeer) events.linked(name)
    }

    private fun closed(key: String) {
        val l = links.remove(key)
        val gone = book.closed(key)
        l ?: return
        reassembler.reset(key)
        val name = l.name ?: return
        gone ?: return
        val rest = book.linkIds(name)
        named = named.toMutableMap().also { if (rest.isEmpty()) it.remove(name) else it[name] = rest }
        if (l.role == Role.PERIPHERAL) {
            // The peer's link to us died: the scanner link we dropped in the tie-break may come back.
            val back = dropped.filterValues { it == gone.keyId }.keys
            for (addr in back) { dropped.remove(addr); policy.include(addr) }
        }
        if (!gone.stillLinked) events.unlinked(name)
    }

    // MARK: Server (peripheral)

    private fun openServer() {
        val s = manager?.openGattServer(context, serverCallback) ?: return
        server = s
        val ch = BluetoothGattCharacteristic(CHARACTERISTIC,
            BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE)
        ch.addDescriptor(BluetoothGattDescriptor(CCCD, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
        serverChar = ch
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(ch)
        s.addService(service)
    }

    private fun advertise() {
        val adv = adapter?.bluetoothLeAdvertiser ?: run { events.problem("This phone cannot advertise over Bluetooth LE; it can still connect to others."); return }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true).build()
        val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).setIncludeDeviceName(false).build()
        adv.startAdvertising(settings, data, advertiseCallback)
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) { Log.i(TAG, "advertising as $displayName") }
        override fun onStartFailure(errorCode: Int) { events.problem("Bluetooth advertising failed (code $errorCode).") }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) { handler.post { try { advertise() } catch (e: SecurityException) { } } }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            handler.post { if (newState == BluetoothProfile.STATE_DISCONNECTED) { serverMtu.remove(device.address); closed("p-" + device.address) } }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            handler.post { serverMtu[device.address] = minOf(512, mtu - 3); links["p-" + device.address]?.mtu = minOf(512, mtu - 3) }
        }

        override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
                                              preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
            handler.post {
                try { if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null) } catch (e: SecurityException) { }
                if (descriptor.uuid != CCCD) return@post
                val key = "p-" + device.address
                if (value != null && value.isNotEmpty() && (value[0].toInt() and 1) == 1) {
                    val l = links.getOrPut(key) { LinkState(key, Role.PERIPHERAL, device).also { it.mtu = serverMtu[device.address] ?: 20 } }
                    ready(l)
                } else closed(key)
            }
        }

        override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
                                                  preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
            handler.post {
                try { if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null) } catch (e: SecurityException) { }
                if (characteristic.uuid != CHARACTERISTIC || value == null) return@post
                val key = "p-" + device.address
                val l = links.getOrPut(key) { LinkState(key, Role.PERIPHERAL, device).also { it.mtu = serverMtu[device.address] ?: 20 } }
                received(value, l)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            handler.post { notifyBusy = false; pumpPeripherals() }
        }
    }

    // MARK: Client (central)

    private fun startScan() {
        val scanner = adapter?.bluetoothLeScanner ?: return
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(listOf(filter), settings, scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) { handler.post { heard(result.device, result.rssi) } }
        override fun onBatchScanResults(results: MutableList<ScanResult>) { handler.post { results.forEach { heard(it.device, it.rssi) } } }
        override fun onScanFailed(errorCode: Int) { events.problem("Bluetooth scan failed (code $errorCode).") }
    }

    private fun heard(device: BluetoothDevice, rssi: Int) {
        if (!running || dropped.containsKey(device.address) || links.containsKey("c-" + device.address)) return
        if (policy.discovered(device.address, rssi)) { heard[device.address] = device; startConnects() }
    }

    /** Starts the connects the policy allows now (cap, signal floor, strongest first, backoff). */
    private fun startConnects() {
        if (!running) return
        for (addr in policy.next(links.size)) {
            val d = heard.remove(addr)
            if (d == null) { policy.disconnected(addr); continue }
            connect(d)
        }
    }

    private fun connect(device: BluetoothDevice) {
        if (!running) return
        val key = "c-" + device.address
        if (links.containsKey(key) || device.address in pending || dropped.containsKey(device.address)) { policy.disconnected(device.address); return }
        pending.add(device.address)
        try {
            val g = device.connectGatt(context, false, clientCallback, BluetoothDevice.TRANSPORT_LE)
            val l = LinkState(key, Role.CENTRAL, device)
            l.gatt = g
            links[key] = l
        } catch (e: SecurityException) { pending.remove(device.address) }
    }

    private val clientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            handler.post {
                val key = "c-" + gatt.device.address
                try {
                    val addr = gatt.device.address
                    if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                        pending.remove(addr)
                        policy.connected(addr)
                        if (!gatt.requestMtu(517)) gatt.discoverServices()
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                        val wasPending = addr in pending
                        val wasLinked = links[key]?.ready == true
                        pending.remove(addr)
                        // Always close: a GATT client left open after status 133 blocks the next connect.
                        gatt.close()
                        closed(key)
                        if (wasPending || !wasLinked) {
                            val failure = if (status == ConnectPolicy.GATT_ERROR_133) ConnectPolicy.Failure.GATT_ERROR_133 else ConnectPolicy.Failure.OTHER
                            val wait = policy.failed(addr, failure)
                            Log.i(TAG, "connect failed status=$status; retry in ${wait} ms")
                            heard[addr] = gatt.device
                            handler.postDelayed({ if (policy.discovered(addr, 127)) startConnects() }, wait)
                        } else {
                            policy.disconnected(addr)
                            if (!dropped.containsKey(addr)) { heard[addr] = gatt.device; policy.discovered(addr, 127); startConnects() }
                        }
                    }
                } catch (e: SecurityException) { }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            handler.post {
                links["c-" + gatt.device.address]?.mtu = minOf(512, (if (status == BluetoothGatt.GATT_SUCCESS) mtu else 23) - 3)
                try { gatt.discoverServices() } catch (e: SecurityException) { }
            }
        }

        @Suppress("DEPRECATION")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            handler.post {
                val l = links["c-" + gatt.device.address] ?: return@post
                try {
                    val ch = gatt.getService(SERVICE)?.getCharacteristic(CHARACTERISTIC)
                    if (ch == null) { gatt.disconnect(); return@post }
                    l.remote = ch
                    gatt.setCharacteristicNotification(ch, true)
                    val d = ch.getDescriptor(CCCD) ?: run { gatt.disconnect(); return@post }
                    if (Build.VERSION.SDK_INT >= 33) gatt.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    else { d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; gatt.writeDescriptor(d) }
                } catch (e: SecurityException) { }
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            handler.post {
                val l = links["c-" + gatt.device.address] ?: return@post
                if (status == BluetoothGatt.GATT_SUCCESS) ready(l) else try { gatt.disconnect() } catch (e: SecurityException) { }
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            handler.post { links["c-" + gatt.device.address]?.let { it.inFlight = false; pump(it) } }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            val copy = value.copyOf()
            handler.post { links["c-" + gatt.device.address]?.let { received(copy, it) } }
        }

        @Deprecated("Android 12 and older")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= 33) return
            val copy = characteristic.value?.copyOf() ?: return
            handler.post { links["c-" + gatt.device.address]?.let { received(copy, it) } }
        }
    }
}
