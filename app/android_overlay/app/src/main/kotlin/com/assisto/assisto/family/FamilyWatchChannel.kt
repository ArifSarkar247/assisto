package com.assisto.assisto.family

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * fcbrain: "com.assisto/family_watch" — the family arrival watch.
 *
 *   start({token, api, fences(JSON), title, body}) -> Boolean  (open app only)
 *   stop()                                           -> null
 *   isOn()                                           -> Boolean (token held)
 *   running()                                        -> Boolean
 *   device()  -> {battery, charging, net, bg_restricted, battery_optimised}
 *   counters()-> today's own fixes / pings (the on-phone battery report)
 *
 * Registered from MainActivity inside the usual try/catch; registering a
 * handler is free and NOTHING runs at launch.
 */
object FamilyWatchChannel {
    private const val NAME = "com.assisto/family_watch"

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> result.success(FamilyWatchService.start(app,
                        call.argument<String>("token") ?: "",
                        call.argument<String>("api") ?: "",
                        call.argument<String>("fences") ?: "[]",
                        call.argument<String>("title") ?: "",
                        call.argument<String>("body") ?: ""))
                    "stop" -> { FamilyWatchService.stop(app); result.success(null) }
                    "isOn" -> result.success(FamilyWatchService.isOn(app))
                    "running" -> result.success(FamilyWatchService.running)
                    "device" -> result.success(FamilyWatchService.device(app))
                    "counters" -> result.success(FamilyWatchService.counters(app))
                    else -> result.notImplemented()
                }
            } catch (_: Throwable) {
                result.success(null)
            }
        }
    }
}
