package com.assisto.assisto.calls

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * callsB — "com.assisto/screenshare" MethodChannel (registered from
 * MainActivity.configureFlutterEngine; handler only, nothing runs at launch).
 *
 *   start({title, body, stop}) -> Bool   start ScreenShareService (call ONLY
 *        after the MediaProjection consent); waits up to ~1.5 s for
 *        startForeground and answers whether it is really running
 *   stop()                     -> void   stop the service
 *   isRunning()                -> Bool
 *   needsService()             -> Bool   Android 10+ (Q) types the service;
 *        14+ (U) REQUIRES it before the projection is used
 * Dart <- "stopRequested": the notification's "Stop sharing" was tapped.
 */
object ScreenShareChannel {
    private const val NAME = "com.assisto/screenshare"
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    fun register(ctx: Context, messenger: BinaryMessenger) {
        val app = ctx.applicationContext
        val ch = MethodChannel(messenger, NAME)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        val ok = ScreenShareService.start(
                            app,
                            call.argument<String>("title") ?: "Sharing your screen",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("stop") ?: "Stop sharing")
                        if (!ok) {
                            result.success(false)
                        } else {
                            waitRunning(result, 0)
                        }
                    }
                    "stop" -> {
                        ScreenShareService.stop(app)
                        result.success(null)
                    }
                    "isRunning" -> result.success(ScreenShareService.running)
                    "needsService" -> result.success(
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                try {
                    result.success(if (call.method == "start") false else null)
                } catch (_: Throwable) {
                }
            }
        }
    }

    /** startForeground runs on the next main-loop turn: poll briefly. */
    private fun waitRunning(result: MethodChannel.Result, tries: Int) {
        if (ScreenShareService.running) {
            result.success(true)
            return
        }
        if (tries >= 15 || ScreenShareService.lastError.isNotEmpty()) {
            result.success(false)
            return
        }
        main.postDelayed({
            try {
                waitRunning(result, tries + 1)
            } catch (_: Throwable) {
                try {
                    result.success(false)
                } catch (_: Throwable) {
                }
            }
        }, 100)
    }

    /** The notification's Stop button. */
    fun onStopRequested() {
        main.post {
            try {
                channel?.invokeMethod("stopRequested", null)
            } catch (_: Throwable) {
            }
        }
    }
}
