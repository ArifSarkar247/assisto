// ps1-photo — goes into MainActivity.configureFlutterEngine (see
// .phaseB/proposals/ps1-photo.md §N3). FLAG_SECURE blocks screenshots and
// screen recording while a FREE user's watermarked preview is on screen.
// Lazy (only when Photo Studio asks), try/caught, UI thread.
package com.assisto.assisto

import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object PhotoSecure {
    private const val CHANNEL = "com.assisto/photo_secure"

    fun register(activity: MainActivity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "enable" -> activity.runOnUiThread {
                            try {
                                activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                        "disable" -> activity.runOnUiThread {
                            try {
                                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } catch (_: Exception) {
                            }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.success(false)
                }
            }
    }
}
