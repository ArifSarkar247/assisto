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
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
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
 * Native -> Dart: "event" {type: connected|disconnected|button|radio, address, user, radioOff}
 *   (radio: Bluetooth turned off/on; disconnected with radioOff=true = the
 *   adapter went off, never a "left behind")
 *
 * LAZY + CRASH-GUARDED: register() only installs a handler; the adapter is
 * touched only when the Bluetooth tag screen calls. Scanning uses
 * BLUETOOTH_SCAN with neverForLocation on Android 12+ (Android 8-11 need
 * the location permission for any BLE scan — asked on the tag screen after
 * its own reason). No background scanning, no foreground service: links live
 * only while the app process runs. itag-proof: the link logic (serialized
 * GATT ops, timeouts, one silent retry, radio off) is ItagEngine.kt — pure
 * Kotlin, JVM unit-tested in CI (itag-proof.yml); this file only adapts
 * Android's BluetoothGatt to it. A vendor quirk returns false/null instead
 * of crashing.
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
                    "ring" -> engine.ring(addr, call.argument<Int>("level") ?: 2, reply(result))
                    "linkLoss" -> engine.linkLoss(addr, call.argument<Int>("level") ?: 0, reply(result))
                    "battery" -> engine.battery(addr) { v -> try { result.success(v) } catch (_: Throwable) {} }
                    "disconnect" -> { engine.disconnect(addr); result.success(true) }
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

    // ---- connect + GATT ops: ItagEngine (pure Kotlin, JVM-tested) -----------

    private val engine: ItagEngine by lazy { ItagEngine(AndroidHost) }

    private fun emit(type: String, address: String, user: Boolean, radioOff: Boolean) {
        main.post {
            try {
                channel?.invokeMethod("event", mapOf(
                    "type" to type, "address" to address, "user" to user, "radioOff" to radioOff))
            } catch (_: Throwable) {}
        }
    }

    private var radioWatch: BroadcastReceiver? = null

    /** Bluetooth on/off while a tag is linked (lazy: first connect only). */
    private fun watchRadio(ctx: Context) {
        if (radioWatch != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                try {
                    if (i == null || i.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
                    when (i.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                        BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF ->
                            main.post { try { engine.onRadio(false) } catch (_: Throwable) {} }
                        BluetoothAdapter.STATE_ON ->
                            main.post { try { engine.onRadio(true) } catch (_: Throwable) {} }
                    }
                } catch (_: Throwable) {}
            }
        }
        try {
            val f = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
            // a protected system broadcast: delivered to a not-exported receiver
            if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED)
            else ctx.registerReceiver(r, f)
            radioWatch = r
        } catch (_: Throwable) {}
    }

    private fun connect(ctx: Context, address: String, result: MethodChannel.Result) {
        watchRadio(ctx)
        engine.connect(address) { ok -> try { result.success(ok) } catch (_: Throwable) {} }
    }

    private fun reply(result: MethodChannel.Result): (Boolean) -> Unit =
        { ok -> try { result.success(ok) } catch (_: Throwable) {} }

    private object AndroidHost : ItagHost {
        override fun radioOn(): Boolean = try {
            ItagChannel.app?.let { ItagChannel.adapter(it)?.isEnabled } == true
        } catch (_: Throwable) { false }

        override fun canConnect(): Boolean = ItagChannel.app?.let { ItagChannel.canConnect(it) } == true

        override fun validAddress(address: String) = BluetoothAdapter.checkBluetoothAddress(address)

        @SuppressLint("MissingPermission")
        override fun open(address: String, events: ItagGattEvents): ItagGatt? {
            val ctx = ItagChannel.app ?: return null
            val a = ItagChannel.adapter(ctx) ?: return null
            val device: BluetoothDevice = a.getRemoteDevice(address)
            val g = device.connectGatt(ctx, false, AndroidCallback(events), BluetoothDevice.TRANSPORT_LE)
                ?: return null
            return AndroidGatt(g)
        }

        override fun post(r: () -> Unit) { ItagChannel.main.post { r() } }
        override fun postDelayed(ms: Long, r: () -> Unit) { ItagChannel.main.postDelayed({ r() }, ms) }
        override fun emit(type: String, address: String, user: Boolean, radioOff: Boolean) =
            ItagChannel.emit(type, address, user, radioOff)
    }

    private fun char(g: BluetoothGatt, svc: UUID, ch: UUID): BluetoothGattCharacteristic? =
        try { g.getService(svc)?.getCharacteristic(ch) } catch (_: Throwable) { null }

    @SuppressLint("MissingPermission")
    private class AndroidGatt(val g: BluetoothGatt) : ItagGatt {
        override fun discoverServices() = g.discoverServices()

        @Suppress("DEPRECATION")
        override fun writeAlert(service: ItagService, level: Int): Boolean {
            val svc = if (service == ItagService.IMMEDIATE_ALERT) ItagChannel.IAS else ItagChannel.LLS
            val c = ItagChannel.char(g, svc, ItagChannel.ALERT) ?: return false
            c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            c.value = byteArrayOf(level.toByte())
            return g.writeCharacteristic(c)
        }

        override fun readBattery(): Boolean {
            val c = ItagChannel.char(g, ItagChannel.BAS, ItagChannel.BATT) ?: return false
            return g.readCharacteristic(c)
        }

        @Suppress("DEPRECATION")
        override fun enableButton(): Boolean {
            val c = ItagChannel.char(g, ItagChannel.BTN_SVC, ItagChannel.BTN) ?: return false
            if (!g.setCharacteristicNotification(c, true)) return false
            val d = c.getDescriptor(ItagChannel.CCCD) ?: return false
            d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            return g.writeDescriptor(d)
        }

        override fun disconnect() = g.disconnect()
        override fun close() = g.close()
    }

    /** BluetoothGattCallback -> ItagGattEvents (the engine hops to main). */
    private class AndroidCallback(val ev: ItagGattEvents) : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) ev.connectionState(true)
            else if (newState == BluetoothProfile.STATE_DISCONNECTED) ev.connectionState(false)
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) =
            ev.servicesDiscovered(status == BluetoothGatt.GATT_SUCCESS)

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) =
            ev.writeDone(status == BluetoothGatt.GATT_SUCCESS)

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) =
            ev.writeDone(status == BluetoothGatt.GATT_SUCCESS)

        @Deprecated("Android 12 and older")
        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) =
            ev.readDone(c.uuid == ItagChannel.BATT, c.value, status == BluetoothGatt.GATT_SUCCESS)

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) =
            ev.readDone(c.uuid == ItagChannel.BATT, value, status == BluetoothGatt.GATT_SUCCESS)

        @Deprecated("Android 12 and older")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            if (c.uuid == ItagChannel.BTN) ev.buttonPressed()
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            if (c.uuid == ItagChannel.BTN) ev.buttonPressed()
        }
    }
}
