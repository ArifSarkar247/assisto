package com.assisto.assisto.antitheft

import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * b6-antitheft — "com.assisto/antitheft" MethodChannel.
 *
 * Registered from MainActivity.configureFlutterEngine (one line; see the
 * proposal). Registering a handler is free — NOTHING runs at launch. The
 * engine (foreground service) only starts when Dart calls start() after the
 * user turned protection on and the server returned a scoped engine token.
 *
 *   capabilities() -> Map   honest device facts for the UI
 *   isRunning()    -> Bool  the real foreground-service state
 *   start({engineToken, apiBase, config, notifTitle, notifBody}) -> Bool
 *   stop()         -> void
 *   flush()        -> void  try an immediate check-in + queue drain
 *
 * Every branch is try/catch so a vendor quirk returns a safe value, never a
 * crash.
 */
object AntiTheftChannel {
    private const val NAME = "com.assisto/antitheft"

    fun register(ctx: Context, messenger: BinaryMessenger) {
        val app = ctx.applicationContext
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "capabilities" -> result.success(capabilities(app))
                    "isRunning" -> result.success(AntiTheftService.running)
                    "start" -> {
                        val token = call.argument<String>("engineToken") ?: ""
                        val api = call.argument<String>("apiBase") ?: ""
                        val cfgMap = call.argument<Map<String, Any?>>("config") ?: emptyMap()
                        val title = call.argument<String>("notifTitle") ?: "Protection on"
                        val body = call.argument<String>("notifBody") ?: ""
                        if (token.isBlank() || api.isBlank()) {
                            result.success(false)
                        } else {
                            val ok = AntiTheftService.start(
                                app, token, api, JSONObject(cfgMap), title, body)
                            result.success(ok)
                        }
                    }
                    "stop" -> { AntiTheftService.stop(app); result.success(null) }
                    "flush" -> { AntiTheftService.flush(app); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                try { result.success(null) } catch (_: Throwable) {}
            }
        }
    }

    private fun capabilities(ctx: Context): Map<String, Any?> {
        val m = HashMap<String, Any?>()
        try {
            m["sdk"] = Build.VERSION.SDK_INT
            m["brand"] = Build.MANUFACTURER ?: ""
            m["model"] = Build.MODEL ?: ""
            // Camera in the background is blocked for normal apps on API 28+.
            m["canCamera"] = IntruderCamera.canAttempt(ctx) &&
                Build.VERSION.SDK_INT < Build.VERSION_CODES.P
            m["hasFrontCamera"] = IntruderCamera.hasFrontCamera(ctx)
            m["cameraXBundled"] = IntruderCamera.available()
            // SIM carrier is sometimes readable; the SIM phone NUMBER almost
            // never is on modern Android, so we always advertise false there.
            m["canReadSim"] = SimInfo.carrier(ctx) != null
            m["canReadSimNumber"] = false
            m["deviceAdmin"] = DeviceAdminLock.isActive(ctx)
            m["location"] = LastLocation.get(ctx) != null
        } catch (_: Throwable) {
        }
        return m
    }
}
