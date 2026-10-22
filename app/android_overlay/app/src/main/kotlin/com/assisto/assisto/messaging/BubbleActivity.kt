package com.assisto.assisto.messaging

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * c3-msg — the expanded bubble window. A plain FlutterActivity (its own
 * engine, created only when the user opens a bubble — never at app launch);
 * Dart asks `takeLaunchChat` on start and opens that one chat. The manifest
 * entry (allowEmbedded / resizeableActivity / documentLaunchMode) is in
 * .phaseB/proposals/c3-msg.md.
 */
class BubbleActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        try {
            C3MessagingChannel.register(this, flutterEngine, inBubble = true)
        } catch (t: Throwable) {
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        try {
            C3MessagingChannel.onNewIntent(intent)
        } catch (t: Throwable) {
        }
    }
}
