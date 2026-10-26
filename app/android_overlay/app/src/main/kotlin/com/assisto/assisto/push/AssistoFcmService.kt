package com.assisto.assisto.push

import android.content.Context
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.ContextHolder
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService

/**
 * Assisto's FCM entry point (replaces the plugin's FlutterFirebaseMessagingService
 * in the manifest — see .phaseB/proposals/a6-leftovers.md).
 *
 * WHY: the auto-init FirebaseInitProvider (a startup ContentProvider) is removed
 * because of the ColorOS startup-provider crash history. Without it, a push that
 * arrives while Assisto is CLOSED would find no default FirebaseApp and the
 * service would throw. So we initialise Firebase here — lazily, only when a push
 * actually arrives — from the google-services.json string resources. If the
 * build has no Firebase config, initializeApp returns null and nothing else
 * happens (no token can exist in that build, so no message can arrive anyway).
 *
 * Everything is wrapped: this can never crash the process.
 */
class AssistoFcmService : FlutterFirebaseMessagingService() {

    override fun onCreate() {
        // The plugin's FlutterFirebaseMessagingInitProvider (a startup
        // ContentProvider that only stores the app context) is removed too;
        // its receiver / engine attach set the same holder, we cover the
        // service path here.
        try {
            if (ContextHolder.getApplicationContext() == null) {
                ContextHolder.setApplicationContext(applicationContext)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "context holder skipped: ${t.javaClass.simpleName}")
        }
        ensureFirebase(this)
        super.onCreate()
    }

    // c3-msg: the plugin's own receiver hands the push to Dart (which
    // decrypts + draws the MessagingStyle conversation); here we only
    // schedule the optional BUBBLE upgrade of that notification. Guarded.
    //
    // ring-everywhere: a CALL push rings NATIVELY first (IncomingCall: CallStyle
    // notification + full-screen intent + ringtone + Telecom self-managed
    // call), before the push is handed to Flutter — a cold / blocked Dart
    // isolate on an aggressive OEM can no longer leave the phone silent. Then
    // the native delivered / ringing ack goes to the server on this (FCM
    // background) thread. Dart still gets the push as a fallback; it sees the
    // ring already showing (same notification id) and draws nothing.
    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        var data: Map<String, String>? = null
        var isCall = false
        var shown = false
        try {
            data = remoteMessage.data
            val ic = com.assisto.assisto.calls.IncomingCall
            if (ic.isCall(data)) {
                isCall = true
                // calls95: confirm delivery FIRST (own thread), before the
                // ring / Telecom / Flutter hand-off can delay it.
                com.assisto.assisto.calls.CallAck.deliveredNow(applicationContext, data)
                shown = ic.onCallPush(applicationContext, data!!)
            } else if (ic.isCancel(data)) {
                ic.onCancelPush(applicationContext, data!!)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "native ring skipped: ${t.javaClass.simpleName}")
        }
        super.onMessageReceived(remoteMessage)
        try {
            com.assisto.assisto.messaging.BubbleHelper.onMessagePush(
                applicationContext, remoteMessage.data
            )
        } catch (t: Throwable) {
            Log.w(TAG, "bubble hook skipped: ${t.javaClass.simpleName}")
        }
        if (isCall && data != null) {
            com.assisto.assisto.calls.CallAck.afterPush(applicationContext, data, shown)
        }
    }

    companion object {
        private const val TAG = "AssistoFcm"

        @JvmStatic
        fun ensureFirebase(context: Context): Boolean {
            return try {
                if (FirebaseApp.getApps(context).isNotEmpty()) {
                    true
                } else {
                    FirebaseApp.initializeApp(context) != null
                }
            } catch (t: Throwable) {
                Log.w(TAG, "Firebase init skipped: ${t.javaClass.simpleName}")
                false
            }
        }
    }
}
