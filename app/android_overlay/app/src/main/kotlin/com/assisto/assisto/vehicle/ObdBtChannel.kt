package com.assisto.assisto.vehicle

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * ELM327 OBD-II dongle over CLASSIC Bluetooth SPP (RFCOMM) — v1-vehicle.
 * Registered from MainActivity.configureFlutterEngine (see
 * .phaseB/proposals/v1-vehicle.md). Most cheap ELM327 v1.5 dongles are
 * classic SPP, not BLE, so no BLE plugin is used.
 *
 * Channel "com.assisto/obd_bt":
 *   state()                         -> "ready" | "off" | "no_permission" | "unavailable"
 *   bonded()                        -> [{name, address}]  (already-paired devices only;
 *                                       we never scan, so BLUETOOTH_SCAN is not needed)
 *   connect({address})              -> Bool
 *   send({cmd, timeoutMs})          -> String (raw reply up to the '>' prompt)
 *   disconnect()                    -> Bool
 *
 * LAZY + CRASH-GUARDED: registering the handler is free; the adapter is only
 * touched when Dart calls a method from the OBD screen. All socket I/O runs on
 * one background thread; every call is try/catch and answers on the main
 * thread, so a vendor Bluetooth quirk returns false/"" instead of crashing.
 */
object ObdBtChannel {
    private const val NAME = "com.assisto/obd_bt"
    private val SPP: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private var io: ExecutorService? = null
    private var socket: BluetoothSocket? = null
    private var input: InputStream? = null
    private var output: OutputStream? = null
    private val main = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
            .setMethodCallHandler { call, result ->
                val ctx = activity.applicationContext
                try {
                    when (call.method) {
                        "state" -> result.success(state(ctx))
                        "bonded" -> result.success(bonded(ctx))
                        "connect" -> {
                            val addr = call.argument<String>("address") ?: ""
                            bg { val ok = connect(ctx, addr); main.post { result.success(ok) } }
                        }
                        "send" -> {
                            val cmd = call.argument<String>("cmd") ?: ""
                            val t = (call.argument<Int>("timeoutMs") ?: 4000).toLong()
                            bg { val r = send(cmd, t); main.post { result.success(r) } }
                        }
                        "disconnect" -> { close(); result.success(true) }
                        else -> result.notImplemented()
                    }
                } catch (_: Throwable) {
                    try { result.success(null) } catch (_: Throwable) {}
                }
            }
    }

    private fun bg(block: () -> Unit) {
        val ex = io ?: Executors.newSingleThreadExecutor().also { io = it }
        ex.execute {
            try { block() } catch (_: Throwable) {}
        }
    }

    private fun hasConnectPerm(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ctx.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    private fun state(ctx: Context): String {
        return try {
            val bm = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val ad = bm?.adapter ?: return "unavailable"
            if (!hasConnectPerm(ctx)) return "no_permission"
            if (!ad.isEnabled) "off" else "ready"
        } catch (_: Throwable) {
            "unavailable"
        }
    }

    @SuppressLint("MissingPermission")
    private fun bonded(ctx: Context): List<Map<String, String>> {
        return try {
            if (!hasConnectPerm(ctx)) return emptyList()
            val bm = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            bm?.adapter?.bondedDevices?.map {
                mapOf("name" to (it.name ?: ""), "address" to it.address)
            } ?: emptyList()
        } catch (_: Throwable) {
            emptyList()
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect(ctx: Context, address: String): Boolean {
        close()
        return try {
            if (!hasConnectPerm(ctx)) return false
            val bm = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val ad = bm?.adapter ?: return false
            val dev = ad.getRemoteDevice(address)
            // cancelDiscovery needs BLUETOOTH_SCAN on 12+; we never scan, so only
            // call it on <= 11 where the legacy BLUETOOTH_ADMIN covers it.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                try { ad.cancelDiscovery() } catch (_: Throwable) {}
            }
            val s = dev.createRfcommSocketToServiceRecord(SPP)
            s.connect()
            socket = s
            input = s.inputStream
            output = s.outputStream
            true
        } catch (_: Throwable) {
            close()
            false
        }
    }

    private fun send(cmd: String, timeoutMs: Long): String {
        val out = output ?: return ""
        val inp = input ?: return ""
        return try {
            while (inp.available() > 0) inp.read()          // drop stale bytes
            out.write((cmd + "\r").toByteArray(Charsets.US_ASCII))
            out.flush()
            val sb = StringBuilder()
            val end = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < end) {
                if (inp.available() > 0) {
                    val c = inp.read()
                    if (c < 0) break
                    if (c.toChar() == '>') break
                    sb.append(c.toChar())
                    if (sb.length > 4096) break
                } else {
                    Thread.sleep(15)
                }
            }
            sb.toString()
        } catch (_: Throwable) {
            ""
        }
    }

    private fun close() {
        try { input?.close() } catch (_: Throwable) {}
        try { output?.close() } catch (_: Throwable) {}
        try { socket?.close() } catch (_: Throwable) {}
        input = null; output = null; socket = null
    }
}
