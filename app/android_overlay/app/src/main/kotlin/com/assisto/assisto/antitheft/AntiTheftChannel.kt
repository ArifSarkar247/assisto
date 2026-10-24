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
 *   resume({notifTitle, notifBody, notifOff, resumeTitle, resumeBody}) -> Bool
 *                       at-heartbeat: app open — protection ON -> start with
 *                       the stored token, rebaseline = false
 *   stop()         -> void
 *   flush()        -> void  try an immediate check-in + queue drain
 *   setQuiet({on}) -> void  owner is on the protection screen: no snatch
 *                        detection (at-falsealarm)
 *   start(..., rebaseline: true) re-records the SIM baseline (switch-on)
 *   configure({config}) -> Bool  new settings from the open app (re-declares
 *                        the foreground types, e.g. adds CAMERA for the
 *                        opt-in intruder photo)
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
                        // own-device: the app's hashed install id, sent as
                        // X-Device-Id with every ingest (same as the app)
                        AntiTheftService.saveDeviceId(app, call.argument<String>("deviceId"))
                        val token = call.argument<String>("engineToken") ?: ""
                        val api = call.argument<String>("apiBase") ?: ""
                        val cfgMap = call.argument<Map<String, Any?>>("config") ?: emptyMap()
                        val title = call.argument<String>("notifTitle") ?: "Protection on"
                        val body = call.argument<String>("notifBody") ?: ""
                        val off = call.argument<String>("notifOff") ?: "Turn off"
                        val rebase = call.argument<Boolean>("rebaseline") ?: false
                        if (token.isBlank() || api.isBlank()) {
                            result.success(false)
                        } else {
                            // at-heartbeat: bn/en texts for the "tap to resume"
                            // notification after a refused background restart
                            try {
                                val rt = call.argument<String>("resumeTitle") ?: ""
                                val rb = call.argument<String>("resumeBody") ?: ""
                                if (rt.isNotBlank()) {
                                    app.getSharedPreferences("assisto_antitheft_engine",
                                        Context.MODE_PRIVATE).edit()
                                        .putString("resumeTitle", rt)
                                        .putString("resumeBody", rb).apply()
                                }
                            } catch (_: Throwable) {}
                            val ok = AntiTheftService.start(
                                app, token, api, JSONObject(cfgMap), title, body, off,
                                rebase)
                            result.success(ok)
                        }
                    }
                    // at-heartbeat: app open/resume — protection ON (token in
                    // prefs) -> start(..., rebaseline = false) or kick a
                    // check-in. Protection off -> false, nothing started.
                    "resume" -> {
                        AntiTheftService.saveDeviceId(app, call.argument<String>("deviceId"))
                        result.success(AntiTheftService.resume(
                        app,
                        call.argument<String>("notifTitle"),
                        call.argument<String>("notifBody"),
                        call.argument<String>("notifOff"),
                        call.argument<String>("resumeTitle"),
                        call.argument<String>("resumeBody")))
                    }
                    "stop" -> { AntiTheftService.stop(app); result.success(null) }
                    "flush" -> { AntiTheftService.flush(app); result.success(null) }
                    "setQuiet" -> {
                        AntiTheftService.setQuiet(call.argument<Boolean>("on") ?: false)
                        result.success(null)
                    }
                    "configure" -> {
                        val cfgMap = call.argument<Map<String, Any?>>("config") ?: emptyMap()
                        result.success(AntiTheftService.configure(app, JSONObject(cfgMap)))
                    }
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
            // Intruder photo is possible on this phone if it has a front
            // camera; it then still needs the camera permission (asked from
            // the open app when the owner switches it on) + device admin.
            m["canCamera"] = IntruderCamera.hasFrontCamera(ctx)
            m["hasFrontCamera"] = IntruderCamera.hasFrontCamera(ctx)
            m["cameraPermission"] = IntruderCamera.hasPermission(ctx)
            // SIM carrier is sometimes readable; the SIM phone NUMBER almost
            // never is on modern Android, so we always advertise false there.
            m["canReadSim"] = SimInfo.carrier(ctx) != null
            m["canReadSimNumber"] = false
            m["deviceAdmin"] = DeviceAdminLock.isActive(ctx)
            m["location"] = LastLocation.get(ctx) != null
            // at-heartbeat: Doze/battery saver delays check-ins (null = unknown)
            m["batteryOptimised"] = AntiTheftService.batteryOptimised(ctx)
        } catch (_: Throwable) {
        }
        return m
    }
}
