package com.assisto.assisto.audio

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

/**
 * audioroute (owner 28 Oct, "call voice does not go to Bluetooth earphones"):
 * the ONE place in the app that changes Android's call-audio routing.
 * Channels: "com.assisto/audio_route" (methods) and
 * "com.assisto/audio_route/events" (device / route changes).
 *
 * Every other Kotlin file is forbidden (CI guard
 * app/test/audio_route_guard_test.dart) from calling AudioManager.setMode,
 * setSpeakerphoneOn, setCommunicationDevice or startBluetoothSco.
 *
 * LAUNCH SAFETY: register() only installs handlers. AudioManager is looked up
 * on the first method call; the device callback is registered only while Dart
 * listens (a call / a recorder is open). Every branch is try/catch and answers
 * a plain value, so an OEM quirk can never crash the app.
 *
 *   beginCommunication()  -> {owner: Bool}  MODE_IN_COMMUNICATION + audio focus;
 *        turns flutter_webrtc's own AudioSwitch off for the session so there
 *        is exactly ONE owner of routing (owner=false: the switch could not be
 *        turned off; Dart then routes through flutter_webrtc instead)
 *   outputs()             -> [{kind, name, id, type}]   kind: earpiece|speaker|bluetooth|wired
 *   active()              -> kind | null
 *   select(kind, id?)     -> Bool   API 31+: setCommunicationDevice;
 *                                   API < 31: SCO / speakerphone
 *   restore()             -> Bool   back to MODE_NORMAL, focus abandoned,
 *                                   SCO off, speakerphone off, AudioSwitch back on
 *   btPermitted()         -> Bool   Android 12+ "Nearby devices" granted
 *   btPresent()           -> Bool   any Bluetooth audio output connected
 *   sdk()                 -> Int
 *   events: {"event":"devices"} | {"event":"active","kind":..}
 */
object AudioRouteChannel {
    private const val TAG = "AssistoAudioRoute"
    private const val METHODS = "com.assisto/audio_route"
    private const val EVENTS = "com.assisto/audio_route/events"

    private var app: Context? = null
    private var am: AudioManager? = null
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var deviceCb: AudioDeviceCallback? = null
    private var commListener: Any? = null
    private var focus: AudioFocusRequest? = null
    private var inCommunication = false
    private var savedMode: Int? = null
    private var weSetSpeaker = false
    private var weStartedSco = false

    fun register(context: Context, messenger: BinaryMessenger) {
        app = context.applicationContext
        MethodChannel(messenger, METHODS).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "beginCommunication" -> result.success(beginCommunication())
                    "outputs" -> result.success(outputs())
                    "active" -> result.success(active())
                    "select" -> result.success(
                        select(call.argument<String>("kind") ?: "",
                            call.argument<Int>("id")))
                    "restore" -> result.success(restore())
                    "btPermitted" -> result.success(btPermitted())
                    "btPresent" -> result.success(btPresent())
                    "sdk" -> result.success(Build.VERSION.SDK_INT)
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "${call.method} failed: ${t.javaClass.simpleName}")
                try { result.success(null) } catch (_: Throwable) {}
            }
        }
        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                startWatching()
            }

            override fun onCancel(arguments: Any?) {
                stopWatching()
                sink = null
            }
        })
    }

    private fun audio(): AudioManager? {
        am?.let { return it }
        val c = app ?: return null
        return try {
            (c.getSystemService(Context.AUDIO_SERVICE) as? AudioManager).also { am = it }
        } catch (_: Throwable) { null }
    }

    private fun emit(m: Map<String, Any?>) {
        main.post {
            try { sink?.success(m) } catch (_: Throwable) {}
        }
    }

    // ------------------------------------------------------------ watching
    private fun startWatching() {
        val a = audio() ?: return
        try {
            if (deviceCb == null) {
                val cb = object : AudioDeviceCallback() {
                    override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) {
                        emit(mapOf("event" to "devices"))
                    }

                    override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) {
                        emit(mapOf("event" to "devices"))
                    }
                }
                a.registerAudioDeviceCallback(cb, main)
                deviceCb = cb
            }
        } catch (t: Throwable) {
            Log.w(TAG, "device callback: ${t.javaClass.simpleName}")
        }
        if (Build.VERSION.SDK_INT >= 31 && commListener == null) {
            try {
                val l = AudioManager.OnCommunicationDeviceChangedListener { d ->
                    emit(mapOf("event" to "active", "kind" to kindOf(d)))
                }
                a.addOnCommunicationDeviceChangedListener(Executor { r -> main.post(r) }, l)
                commListener = l
            } catch (t: Throwable) {
                Log.w(TAG, "comm listener: ${t.javaClass.simpleName}")
            }
        }
    }

    private fun stopWatching() {
        val a = audio() ?: return
        try { deviceCb?.let { a.unregisterAudioDeviceCallback(it) } } catch (_: Throwable) {}
        deviceCb = null
        if (Build.VERSION.SDK_INT >= 31) {
            try {
                val l = commListener
                if (l is AudioManager.OnCommunicationDeviceChangedListener) {
                    a.removeOnCommunicationDeviceChangedListener(l)
                }
            } catch (_: Throwable) {}
        }
        commListener = null
    }

    // --------------------------------------------------------- device kinds
    private fun kindOf(d: AudioDeviceInfo?): String? {
        if (d == null) return null
        return when (d.type) {
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_HEARING_AID -> "bluetooth"
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET -> "wired"
            else -> if (Build.VERSION.SDK_INT >= 31 &&
                (d.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    d.type == AudioDeviceInfo.TYPE_BLE_SPEAKER)) "bluetooth" else null
        }
    }

    /** Candidate devices for call audio: API 31+ the system's own list of
     *  communication devices; older phones the connected outputs. */
    private fun candidates(): List<AudioDeviceInfo> {
        val a = audio() ?: return emptyList()
        return try {
            if (Build.VERSION.SDK_INT >= 31) {
                a.availableCommunicationDevices
            } else {
                a.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList()
            }
        } catch (_: Throwable) { emptyList() }
    }

    private fun outputs(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val seen = HashSet<String>()
        // a BT headset appears twice before API 31 (A2DP + SCO): prefer SCO
        val list = candidates().sortedBy { if (it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) 0 else 1 }
        for (d in list) {
            val k = kindOf(d) ?: continue
            if (!seen.add(k)) continue
            var name = ""
            try { name = d.productName?.toString() ?: "" } catch (_: Throwable) {}
            out.add(mapOf("kind" to k, "name" to name, "id" to d.id, "type" to d.type))
        }
        // phones always have these two even when an old OEM list omits one
        val hasTelephony = try {
            app?.packageManager?.hasSystemFeature(PackageManager.FEATURE_TELEPHONY) == true
        } catch (_: Throwable) { true }
        if (hasTelephony && "earpiece" !in seen && Build.VERSION.SDK_INT < 31) {
            out.add(mapOf("kind" to "earpiece", "name" to "", "id" to null, "type" to -1))
        }
        if ("speaker" !in seen) {
            out.add(mapOf("kind" to "speaker", "name" to "", "id" to null, "type" to -1))
        }
        return out
    }

    @Suppress("DEPRECATION")
    private fun active(): String? {
        val a = audio() ?: return null
        return try {
            if (Build.VERSION.SDK_INT >= 31) {
                kindOf(a.communicationDevice)
            } else {
                when {
                    a.isSpeakerphoneOn -> "speaker"
                    a.isBluetoothScoOn -> "bluetooth"
                    a.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                        .any { kindOf(it) == "wired" } -> "wired"
                    else -> "earpiece"
                }
            }
        } catch (_: Throwable) { null }
    }

    // --------------------------------------------------------- the session
    private fun beginCommunication(): Map<String, Any?> {
        val owner = setWebrtcAudioSwitch(false)
        val a = audio() ?: return mapOf("owner" to owner)
        try {
            if (Build.VERSION.SDK_INT >= 26 && focus == null) {
                val f = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build())
                    .setOnAudioFocusChangeListener { }
                    .build()
                a.requestAudioFocus(f)
                focus = f
            }
        } catch (t: Throwable) {
            Log.w(TAG, "focus: ${t.javaClass.simpleName}")
        }
        try {
            if (!inCommunication) savedMode = a.mode
            a.mode = AudioManager.MODE_IN_COMMUNICATION
            inCommunication = true
        } catch (t: Throwable) {
            Log.w(TAG, "mode: ${t.javaClass.simpleName}")
        }
        return mapOf("owner" to owner)
    }

    @Suppress("DEPRECATION")
    private fun select(kind: String, id: Int?): Boolean {
        val a = audio() ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= 31) {
                val list = a.availableCommunicationDevices
                val d = list.firstOrNull { id != null && it.id == id && kindOf(it) == kind }
                    ?: list.firstOrNull { kindOf(it) == kind && it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                    ?: list.firstOrNull { kindOf(it) == kind }
                    ?: return false
                a.setCommunicationDevice(d)
            } else {
                when (kind) {
                    "bluetooth" -> {
                        if (a.isSpeakerphoneOn) a.isSpeakerphoneOn = false
                        weSetSpeaker = false
                        a.startBluetoothSco()
                        a.isBluetoothScoOn = true
                        weStartedSco = true
                    }
                    "speaker" -> {
                        stopSco(a)
                        a.isSpeakerphoneOn = true
                        weSetSpeaker = true
                    }
                    else -> { // earpiece / wired: Android picks wired over earpiece
                        stopSco(a)
                        a.isSpeakerphoneOn = false
                        weSetSpeaker = false
                    }
                }
                emit(mapOf("event" to "active", "kind" to kind))
                true
            }
        } catch (t: Throwable) {
            Log.w(TAG, "select $kind: ${t.javaClass.simpleName}")
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun stopSco(a: AudioManager) {
        if (!weStartedSco && !a.isBluetoothScoOn) return
        try {
            a.isBluetoothScoOn = false
            a.stopBluetoothSco()
        } catch (_: Throwable) {}
        weStartedSco = false
    }

    /** Always safe to call (idempotent): music / videos never stay stuck in
     *  call mode or on the earpiece after a call. */
    @Suppress("DEPRECATION")
    private fun restore(): Boolean {
        val a = audio()
        if (a != null) {
            if (Build.VERSION.SDK_INT >= 31) {
                try { a.clearCommunicationDevice() } catch (_: Throwable) {}
            }
            stopSco(a)
            try {
                if (weSetSpeaker || (Build.VERSION.SDK_INT < 31 && inCommunication)) {
                    a.isSpeakerphoneOn = false
                }
            } catch (_: Throwable) {}
            weSetSpeaker = false
            try {
                if (inCommunication || a.mode == AudioManager.MODE_IN_COMMUNICATION) {
                    val back = savedMode ?: AudioManager.MODE_NORMAL
                    a.mode = if (back == AudioManager.MODE_IN_COMMUNICATION) AudioManager.MODE_NORMAL else back
                }
            } catch (_: Throwable) {}
            try {
                if (Build.VERSION.SDK_INT >= 26) focus?.let { a.abandonAudioFocusRequest(it) }
            } catch (_: Throwable) {}
        }
        focus = null
        inCommunication = false
        savedMode = null
        setWebrtcAudioSwitch(true)
        return true
    }

    private fun btPermitted(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        val c = app ?: return false
        return try {
            c.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) { false }
    }

    private fun btPresent(): Boolean {
        val a = audio() ?: return false
        return try {
            a.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { kindOf(it) == "bluetooth" }
        } catch (_: Throwable) { false }
    }

    /**
     * flutter_webrtc ships its own audio switch (com.cloudwebrtc.webrtc.audio.
     * AudioSwitchManager) that also sets the mode and picks devices; two owners
     * fight (the root cause of earpiece-instead-of-Bluetooth). It is turned
     * OFF for our calls and back ON afterwards (Shop live view keeps the old
     * behaviour). Reflection: no compile-time dependency on plugin internals;
     * the class is kept by flutter_webrtc's consumer ProGuard rules.
     * Returns true when the switch is in the requested state.
     */
    private fun setWebrtcAudioSwitch(enabled: Boolean): Boolean {
        return try {
            val cls = Class.forName("com.cloudwebrtc.webrtc.audio.AudioSwitchManager")
            if (!enabled) {
                try {
                    val inst = cls.getField("instance").get(null)
                    inst?.javaClass?.getMethod("stop")?.invoke(inst)
                } catch (_: Throwable) {}
            }
            cls.getMethod("setAudioSessionManagementEnabled", Boolean::class.javaPrimitiveType)
                .invoke(null, enabled)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "webrtc audio switch: ${t.javaClass.simpleName}")
            false
        }
    }
}
