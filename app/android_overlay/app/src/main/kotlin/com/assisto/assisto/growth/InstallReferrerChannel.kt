package com.assisto.assisto.growth

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * invite-join: Google Play Install Referrer, read ONCE after install so a
 * person who tapped "Get Assisto" on lifeassisto.com/i/<CODE> lands straight
 * on "Join X's circle" (Play passes `referrer=ci=<CODE>`).
 *
 * Channel "com.assisto/install_referrer"
 *   get() -> String? the raw referrer string ("ci=ABCD…&…"), or null when
 *            Play has none / the service is missing (sideloaded APK, no Play
 *            Store, old Play) / it takes longer than 5 s.
 *
 * LAZY + CRASH-GUARDED: registering the handler is free; the Play service is
 * bound only when Dart calls get() (seconds after the first frame, once per
 * install — Dart remembers it asked). No ContentProvider, no startup work.
 * Every path answers exactly once; any Throwable (incl. NoClassDefFoundError
 * when the library is absent) answers null.
 */
object InstallReferrerChannel {
    private const val NAME = "com.assisto/install_referrer"
    private const val TIMEOUT_MS = 5000L

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            if (call.method != "get") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val done = AtomicBoolean(false)
            val main = Handler(Looper.getMainLooper())
            fun answer(v: String?) {
                if (done.compareAndSet(false, true)) {
                    main.post { try { result.success(v) } catch (e: Throwable) {} }
                }
            }
            try {
                read(context.applicationContext, ::answer)
                main.postDelayed({ answer(null) }, TIMEOUT_MS)
            } catch (e: Throwable) {
                answer(null)
            }
        }
    }

    private fun read(ctx: Context, answer: (String?) -> Unit) {
        val client = com.android.installreferrer.api.InstallReferrerClient
            .newBuilder(ctx).build()
        client.startConnection(object :
            com.android.installreferrer.api.InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(code: Int) {
                var v: String? = null
                try {
                    if (code == com.android.installreferrer.api
                            .InstallReferrerClient.InstallReferrerResponse.OK) {
                        v = client.installReferrer?.installReferrer
                    }
                } catch (e: Throwable) {
                }
                try { client.endConnection() } catch (e: Throwable) {}
                answer(v)
            }

            override fun onInstallReferrerServiceDisconnected() {
                answer(null)
            }
        })
    }
}
