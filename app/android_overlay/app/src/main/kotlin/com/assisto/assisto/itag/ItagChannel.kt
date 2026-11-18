package com.assisto.assisto.itag

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.UUID

/**
 * itag (W7, flag itag_tags): the cheap open "iTag" BLE key finder.
 *
 *   Immediate Alert 0x1802 / Alert Level 0x2A06  -> ring the tag (0 off, 2 high)
 *   Link Loss       0x1803 / Alert Level 0x2A06  -> the tag beeps by itself when the link drops
 *   Battery         0x180F / Battery Level 0x2A19
 *   Button          0xFFE0 / 0xFFE1 (notify)     -> the tag's button pressed
 *
 * Channel "com.assisto/itag" (Dart -> native):
 *   state()                 -> {state: ready|off|no_permission|location_off|unsupported, sdk}
 *   scan({ms})              -> [{address, name, rssi, likely}]
 *   connect({address})      -> Bool (true once services are found)
 *   ring({address, level})  -> Bool
 *   linkLoss({address, level}) -> Bool
 *   battery({address})      -> Int? (0..100)
 *   disconnect({address})   -> Bool
 *   openSettings()          -> Bool
 * Native -> Dart: "event" {type: connected|disconnected|button, address, user}
 *
 * LAZY + CRASH-GUARDED: register() only installs a handler; the adapter is
 * touched only when the Bluetooth tag screen calls. Scanning uses
 * BLUETOOTH_SCAN with neverForLocation on Android 12+ (Android 8-11 need
 * the location permission for any BLE scan — asked on the tag screen after
 * its own reason). No background scanning, no foreground service: links live
 * only while the app process runs. Every GATT step is serialized (one op at a
 * time, 4 s timeout) and every callback is try/catch — a vendor quirk returns
 * false/null instead of crashing.
 */
object ItagChannel {
    private const val NAME = "com.assisto/itag"
    private fun u16(v: Int): UUID =
        UUID.fromString(String.format("0000%04x-0000-1000-8000-00805f9b34fb", v))

    private val IAS = u16(0x1802)
    private val LLS = u16(0x1803)
    private val ALERT = u16(0x2A06)
    private val BAS = u16(0x180F)
    private val BATT = u16(0x2A19)
    private val BTN_SVC = u16(0xFFE0)
    private val BTN = u16(0xFFE1)
    private val CCCD = u16(0x2902)

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var app: Context? = null
    private var activity: WeakReference<Activity>? = null
    private val links = HashMap<String, Link>()

    private class Op(
        val run: (BluetoothGatt) -> Boolean,
        val done: (Any?) -> Unit,
        val timeoutMs: Long = 4000,
    ) {
        var finished = false
    }

    private class Link(val address: String) {
        var gatt: BluetoothGatt? = null
        var ready = false
        var userClosed = false
        var pendingConnect: MethodChannel.Result? = null
        val queue = ArrayDeque<Op>()
        var busy: Op? = null
    }

    fun register(activity: Activity, messenger: BinaryMessenger) {
        this.activity = WeakReference(activity)
        app = activity.applicationContext
        val ch = MethodChannel(messenger, NAME)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                val ctx = app ?: activity.applicationContext
                val addr = call.argument<String>("address") ?: ""
                when (call.method) {
                    "state" -> result.success(mapOf("state" to state(ctx), "sdk" to Build.VERSION.SDK_INT))
                    "scan" -> scan(ctx, (call.argument<Int>("ms") ?: 8000).toLong(), result)
                    "connect" -> connect(ctx, addr, result)
                    "ring" -> writeAlert(addr, IAS, call.argument<Int>("level") ?: 2, result)
                    "linkLoss" -> writeAlert(addr, LLS, call.argument<Int>("level") ?: 0, result)
                    "battery" -> readBattery(addr, result)
                    "disconnect" -> { close(addr, user = true); result.success(true) }
                    "openSettings" -> result.success(openSettings())
                    else -> result.notImplemented()
                }
            } catch (_: Throwable) {
                try { result.success(null) } catch (_: Throwable) {}
            }
        }
    }

    // ---- state / permissions ----------------------------------------------

    private fun granted(ctx: Context, p: String) =
        ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun canScan(ctx: Context) = if (Build.VERSION.SDK_INT >= 31)
        granted(ctx, Manifest.permission.BLUETOOTH_SCAN)
    else granted(ctx, Manifest.permission.ACCESS_FINE_LOCATION)

    private fun canConnect(ctx: Context) = if (Build.VERSION.SDK_INT >= 31)
        granted(ctx, Manifest.permission.BLUETOOTH_CONNECT) else true

    private fun adapter(ctx: Context): BluetoothAdapter? =
        (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun state(ctx: Context): String {
        if (!ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) return "unsupported"
        val a = adapter(ctx) ?: return "unsupported"
        if (!canScan(ctx) || !canConnect(ctx)) return "no_permission"
        if (!a.isEnabled) return "off"
        if (Build.VERSION.SDK_INT < 31) {
            // Android 8-11 return no BLE scan results with location services off
            val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            val on = try {
                if (Build.VERSION.SDK_INT >= 28) lm?.isLocationEnabled ?: true
                else lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true ||
                    lm?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true
            } catch (_: Throwable) { true }
            if (!on) return "location_off"
        }
        return "ready"
    }

    private fun openSettings(): Boolean {
        val act = activity?.get() ?: return false
        return try {
            act.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
            true
        } catch (_: Throwable) { false }
    }

    // ---- scan --------------------------------------------------------------

    @SuppressLint("MissingPermission")
    private fun scan(ctx: Context, ms: Long, result: MethodChannel.Result) {
        val a = adapter(ctx)
        val scanner = if (a != null && a.isEnabled && canScan(ctx)) a.bluetoothLeScanner else null
        if (scanner == null) { result.success(emptyList<Any>()); return }
        val found = LinkedHashMap<String, Map<String, Any>>()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult?) {
                try {
                    if (r == null) return
                    val rec = r.scanRecord
                    var name = rec?.deviceName ?: ""
                    if (name.isEmpty() && canConnect(ctx)) name = try { r.device.name ?: "" } catch (_: Throwable) { "" }
                    val uuids = rec?.serviceUuids ?: emptyList<ParcelUuid>()
                    val likely = name.lowercase().contains("itag") ||
                        uuids.any { it.uuid == BTN_SVC || it.uuid == IAS }
                    if (name.isEmpty() && !likely) return
                    found[r.device.address] = mapOf(
                        "address" to r.device.address,
                        "name" to name.trim(),
                        "rssi" to r.rssi,
                        "likely" to likely,
                    )
                } catch (_: Throwable) {}
            }
        }
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        try {
            scanner.startScan(null, settings, cb)
        } catch (_: Throwable) { result.success(emptyList<Any>()); return }
        main.postDelayed({
            try { scanner.stopScan(cb) } catch (_: Throwable) {}
            try { result.success(found.values.toList()) } catch (_: Throwable) {}
        }, ms.coerceIn(2000, 20000))
    }

    // ---- connect + GATT ops -----------------------------------------------

    private fun emit(type: String, address: String, user: Boolean = false) {
        main.post {
            try {
                channel?.invokeMethod("event", mapOf("type" to type, "address" to address, "user" to user))
            } catch (_: Throwable) {}
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect(ctx: Context, address: String, result: MethodChannel.Result) {
        val a = adapter(ctx)
        if (a == null || !a.isEnabled || !canConnect(ctx) || !BluetoothAdapter.checkBluetoothAddress(address)) {
            result.success(false); return
        }
        val existing = links[address]
        if (existing?.ready == true) { result.success(true); return }
        existing?.let { close(address, user = true, silent = true) }
        val link = Link(address)
        link.pendingConnect = result
        links[address] = link
        val device: BluetoothDevice = a.getRemoteDevice(address)
        link.gatt = try {
            device.connectGatt(ctx, false, callback(link), BluetoothDevice.TRANSPORT_LE)
        } catch (_: Throwable) { null }
        if (link.gatt == null) { links.remove(address); finishConnect(link, false); return }
        main.postDelayed({
            if (link.pendingConnect != null) {
                finishConnect(link, false)
                close(address, user = true, silent = true)
            }
        }, 15000)
    }

    private fun finishConnect(link: Link, ok: Boolean) {
        val r = link.pendingConnect ?: return
        link.pendingConnect = null
        try { r.success(ok) } catch (_: Throwable) {}
    }

    @SuppressLint("MissingPermission")
    private fun close(address: String, user: Boolean, silent: Boolean = false) {
        val link = links.remove(address) ?: return
        link.userClosed = user
        link.ready = false
        failAll(link)
        try { link.gatt?.disconnect() } catch (_: Throwable) {}
        try { link.gatt?.close() } catch (_: Throwable) {}
        link.gatt = null
        if (!silent) emit("disconnected", address, user)
    }

    private fun failAll(link: Link) {
        link.busy?.let { if (!it.finished) { it.finished = true; try { it.done(false) } catch (_: Throwable) {} } }
        link.busy = null
        while (link.queue.isNotEmpty()) {
            val op = link.queue.removeFirst()
            try { op.done(false) } catch (_: Throwable) {}
        }
    }

    private fun enqueue(link: Link, op: Op) {
        link.queue.addLast(op)
        pump(link)
    }

    private fun pump(link: Link) {
        if (link.busy != null) return
        val g = link.gatt ?: return failAll(link)
        val op = link.queue.removeFirstOrNull() ?: return
        link.busy = op
        val started = try { op.run(g) } catch (_: Throwable) { false }
        if (!started) { complete(link, op, false); return }
        main.postDelayed({ complete(link, op, null) }, op.timeoutMs)
    }

    private fun complete(link: Link, op: Op, value: Any?) {
        if (op.finished) return
        op.finished = true
        if (link.busy === op) link.busy = null
        try { op.done(value) } catch (_: Throwable) {}
        pump(link)
    }

    private fun char(g: BluetoothGatt, svc: UUID, ch: UUID): BluetoothGattCharacteristic? =
        try { g.getService(svc)?.getCharacteristic(ch) } catch (_: Throwable) { null }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun writeAlert(address: String, svc: UUID, level: Int, result: MethodChannel.Result) {
        val link = links[address]
        if (link == null || !link.ready) { result.success(false); return }
        enqueue(link, Op({ g ->
            val c = char(g, svc, ALERT) ?: return@Op false
            c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            c.value = byteArrayOf(level.coerceIn(0, 2).toByte())
            g.writeCharacteristic(c)
            // a write without response may never call back on some phones:
            // the short timeout below counts a started write as sent
        }, { v -> try { result.success(v != false) } catch (_: Throwable) {} }, 600))
    }

    @SuppressLint("MissingPermission")
    private fun readBattery(address: String, result: MethodChannel.Result) {
        val link = links[address]
        if (link == null || !link.ready) { result.success(null); return }
        enqueue(link, Op({ g ->
            val c = char(g, BAS, BATT) ?: return@Op false
            g.readCharacteristic(c)
        }, { v -> try { result.success(v as? Int) } catch (_: Throwable) {} }))
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun enableButton(link: Link) {
        enqueue(link, Op({ g ->
            val c = char(g, BTN_SVC, BTN) ?: return@Op false
            if (!g.setCharacteristicNotification(c, true)) return@Op false
            val d = c.getDescriptor(CCCD) ?: return@Op false
            d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            g.writeDescriptor(d)
        }, { }))
    }

    private fun callback(link: Link) = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                try {
                    if (links[link.address] !== link) return@post
                    if (newState == BluetoothProfile.STATE_CONNECTED) {
                        if (!gatt.discoverServices()) close(link.address, user = false)
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                        val wasReady = link.ready
                        finishConnect(link, false)
                        close(link.address, user = false, silent = !wasReady)
                    }
                } catch (_: Throwable) {}
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post {
                try {
                    if (links[link.address] !== link) return@post
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        finishConnect(link, false); close(link.address, user = true, silent = true); return@post
                    }
                    link.ready = true
                    enableButton(link)
                    finishConnect(link, true)
                    emit("connected", link.address)
                } catch (_: Throwable) {}
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            main.post { link.busy?.let { complete(link, it, status == BluetoothGatt.GATT_SUCCESS) } }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            main.post { link.busy?.let { complete(link, it, status == BluetoothGatt.GATT_SUCCESS) } }
        }

        private fun battery(c: BluetoothGattCharacteristic, value: ByteArray?, status: Int) {
            val v = if (status == BluetoothGatt.GATT_SUCCESS && c.uuid == BATT && value != null && value.isNotEmpty())
                (value[0].toInt() and 0xFF).coerceIn(0, 100) else null
            main.post { link.busy?.let { complete(link, it, v) } }
        }

        @Deprecated("Android 12 and older")
        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            battery(c, c.value, status)
        }

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            battery(c, value, status)
        }

        @Deprecated("Android 12 and older")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            if (c.uuid == BTN) emit("button", link.address)
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            if (c.uuid == BTN) emit("button", link.address)
        }
    }
}
