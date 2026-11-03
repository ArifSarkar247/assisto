package com.assisto.assisto.messaging

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * c3-msg + bubbles (owner 2 Nov) — the expanded bubble window: a small,
 * resizable FlutterActivity (manifest: allowEmbedded / resizeableActivity /
 * documentLaunchMode="always", see android.yml "c3-msg") created only when
 * the user opens a bubble — never at app launch.
 *
 * It runs the LIGHTWEIGHT Dart entrypoint `bubbleMain` (lib/main.dart →
 * lib/messaging/bubble_main.dart): one chat (read + reply) and nothing else
 * — no home, no push/FCM start, no call runtime, no sync — so a bubble can
 * never double-ring a call or double-draw a notification. Dart asks
 * `takeLaunchChat` on start; calls / the full app go through "openInApp".
 */
class BubbleActivity : FlutterActivity() {
    private var bubbleChannel: MethodChannel? = null

    override fun getDartEntrypointFunctionName(): String = "bubbleMain"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        try {
            bubbleChannel = C3MessagingChannel.register(this, flutterEngine, inBubble = true)
        } catch (t: Throwable) {
        }
    }

    /**
     * circlebub: Back on the chat's first screen must COLLAPSE the bubble.
     * Flutter's default (no route left) calls finish(), and Android REMOVES
     * a bubble whose task finished — the bubble vanished on Back. Instead we
     * take Android's own "back on task root" path (Activity.onBackPressed of
     * the platform, which the bubble host turns into a collapse); the chat
     * stays loaded for the next tap. Fallback: move the task back. Never
     * throws; false = Flutter's default (finish).
     */
    override fun popSystemNavigator(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            java.lang.invoke.MethodHandles.lookup().findSpecial(
                android.app.Activity::class.java, "onBackPressed",
                java.lang.invoke.MethodType.methodType(Void.TYPE),
                BubbleActivity::class.java
            ).invokeWithArguments(this)
            true
        } catch (t: Throwable) {
            try {
                moveTaskToBack(true)
            } catch (t2: Throwable) {
                false
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        try {
            C3MessagingChannel.onNewIntent(intent, bubbleChannel)
        } catch (t: Throwable) {
        }
    }

    // the chat's document / sound pickers answer through the channel object
    @Deprecated("Legacy result path kept for the startActivityForResult pickers")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        try {
            if (C3MessagingChannel.onActivityResult(this, requestCode, resultCode, data)) return
        } catch (t: Throwable) {
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        bubbleChannel = null
        super.onDestroy()
    }
}
