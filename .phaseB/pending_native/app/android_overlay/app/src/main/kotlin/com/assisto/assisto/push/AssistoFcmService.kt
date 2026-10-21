package com.assisto.assisto.push

import android.content.Context
import android.util.Log
import com.google.firebase.FirebaseApp
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
