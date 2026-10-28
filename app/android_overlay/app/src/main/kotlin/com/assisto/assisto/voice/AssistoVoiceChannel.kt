package com.assisto.assisto.voice

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.app.SearchManager
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.os.Build
import android.provider.AlarmClock
import android.provider.MediaStore
import android.provider.ContactsContract
import android.provider.Settings
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Part 3 — Assisto Voice native bridge. Channel: "com.assisto/voice".
 *
 * LAUNCH SAFETY: register() only installs a MethodCallHandler (no I/O, no
 * system services). TextToSpeech, CameraManager, the PackageManager scan and
 * the contacts query are created on the FIRST call that needs them. Every
 * branch is wrapped in try/catch and answers with a plain status string, so a
 * failing OEM API can never crash the app — Dart shows an honest message.
 */
object AssistoVoiceChannel {
    private const val CHANNEL = "com.assisto/voice"

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var pendingSpeak: (() -> Unit)? = null
    private var utterSeq = 0
    private val pending = HashMap<String, MethodChannel.Result>()
    private val main = Handler(Looper.getMainLooper())

    private fun finish(id: String?) {
        main.post {
            val r = if (id != null) pending.remove(id) else null
            try { r?.success("ok") } catch (ignored: Exception) {}
        }
    }

    /** Resolve every waiting speak() call (a new one flushes the old). */
    private fun flushPending() {
        val all = pending.values.toList()
        pending.clear()
        for (r in all) {
            try { r.success("ok") } catch (ignored: Exception) {}
        }
    }

    private val progress = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {}
        override fun onDone(utteranceId: String?) = finish(utteranceId)
        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) = finish(utteranceId)
        override fun onStop(utteranceId: String?, interrupted: Boolean) = finish(utteranceId)
    }

    /** Call from MainActivity.configureFlutterEngine (wrapped in try/catch). */
    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "ping" -> result.success(true)
                    "consumeAssistLaunch" -> result.success(VoiceLaunchState.consume())
                    "isDefaultAssistant" -> result.success(isDefaultAssistant(activity))
                    "openAssistantSettings" -> result.success(openAssistantSettings(activity))
                    "speak" -> speak(
                        activity.applicationContext,
                        call.argument<String>("text") ?: "",
                        call.argument<String>("lang") ?: "en",
                        result
                    )
                    "stopSpeaking" -> {
                        try { tts?.stop() } catch (ignored: Exception) {}
                        flushPending()
                        result.success(null)
                    }
                    "openTtsSettings" -> result.success(
                        startSafely(activity, Intent("com.android.settings.TTS_SETTINGS"))
                    )
                    // aivoice: where the user picks Google as the speech engine
                    // (ColorOS / MIUI default to their own). Keyboard settings
                    // as the fallback; never throws.
                    "openVoiceInputSettings" -> result.success(
                        startSafely(activity, Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)) ||
                            startSafely(activity, Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                    )
                    "torch" -> result.success(torch(activity, call.argument<Boolean>("on") ?: true))
                    "setAlarm" -> result.success(
                        setAlarm(
                            activity,
                            call.argument<Int>("hour"),
                            call.argument<Int>("minute"),
                            call.argument<String>("label") ?: "Assisto"
                        )
                    )
                    "setTimer" -> result.success(
                        setTimer(
                            activity,
                            call.argument<Int>("seconds"),
                            call.argument<String>("label") ?: "Assisto"
                        )
                    )
                    "listApps" -> result.success(listApps(activity))
                    "launchApp" -> result.success(launchApp(activity, call.argument<String>("package") ?: ""))
                    "contacts" -> result.success(contacts(activity))
                    "callNow" -> result.success(callNow(activity, call.argument<String>("number") ?: ""))
                    "youtubeSearch" -> result.success(youtubeSearch(activity, call.argument<String>("query") ?: ""))
                    "wakeStatus" -> result.success(WakeWordService.status(activity))
                    "wakeStart" -> result.success(
                        WakeWordService.start(
                            activity,
                            call.argument<String>("accessKey") ?: "",
                            call.argument<String>("keywordPath") ?: "",
                            (call.argument<Double>("sensitivity") ?: 0.6).toFloat(),
                            call.argument<String>("title") ?: "Assisto",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("stopLabel") ?: "Stop",
                            call.argument<String>("tapText") ?: ""
                        )
                    )
                    "isLocked" -> result.success(isLocked(activity))
                    "requestUnlock" -> requestUnlock(activity, result)
                    "leaveLockScreen" -> {
                        leaveLockScreen(activity, call.argument<Boolean>("moveBack") ?: false)
                        result.success(null)
                    }
                    "musicApps" -> result.success(musicApps(activity))
                    "playFromSearch" -> result.success(
                        playFromSearch(
                            activity,
                            call.argument<String>("package") ?: "",
                            call.argument<String>("query") ?: "",
                            call.argument<String>("artist"),
                            call.argument<String>("title")
                        )
                    )
                    "openYoutubeVideo" -> result.success(
                        openYoutubeVideo(activity, call.argument<String>("id") ?: "")
                    )
                    "wakeStop" -> {
                        WakeWordService.stop(activity)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                // Never let a native failure escape to the platform thread.
                try { result.success(null) } catch (ignored: Throwable) {}
            }
        }
    }

    // ---- launch over the lock screen ------------------------------------------

    /**
     * Call from MainActivity.onCreate and onNewIntent. For an assist / wake
     * launch on a LOCKED phone it lets this one launch show over the keyguard
     * (Dart then asks to unlock before anything private runs).
     */
    @JvmStatic
    fun applyLaunchIntent(activity: Activity, intent: Intent?) {
        try {
            if (intent?.getBooleanExtra("assisto_voice", false) != true) return
            VoiceLaunchState.mark()
            if (intent.getBooleanExtra("assisto_voice_locked", false) &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                activity.setShowWhenLocked(true)
                activity.setTurnScreenOn(true)
            }
            intent.removeExtra("assisto_voice")
        } catch (ignored: Throwable) {}
    }

    private fun isLocked(ctx: Context): Boolean = try {
        (ctx.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
    } catch (ignored: Throwable) {
        false
    }

    private fun requestUnlock(activity: Activity, result: MethodChannel.Result) {
        if (!isLocked(activity)) { result.success(true); return }
        var done = false
        fun reply(v: Boolean) {
            if (done) return
            done = true
            try { result.success(v) } catch (ignored: Throwable) {}
        }
        try {
            val km = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            km.requestDismissKeyguard(activity, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() = reply(true)
                override fun onDismissCancelled() = reply(false)
                override fun onDismissError() = reply(false)
            })
        } catch (ignored: Throwable) {
            reply(false)
        }
    }

    private fun leaveLockScreen(activity: Activity, moveBack: Boolean) {
        try {
            // NOTE: we do NOT reset showWhenLocked here — the integrated
            // manifest (a6 FCM) declares MainActivity showWhenLocked="true"
            // statically for incoming calls / SOS; clearing it at runtime would
            // break those. We only hand the phone back to the lock screen.
            if (moveBack && isLocked(activity)) activity.moveTaskToBack(true)
        } catch (ignored: Throwable) {}
    }

    // ---- music -------------------------------------------------------------------

    private val MUSIC_PKGS = listOf(
        "com.google.android.apps.youtube.music",
        "com.spotify.music",
        "com.google.android.youtube"
    )

    private fun musicApps(ctx: Context): List<String> = MUSIC_PKGS.filter { p ->
        try {
            ctx.packageManager.getLaunchIntentForPackage(p) != null
        } catch (ignored: Throwable) {
            false
        }
    }

    /**
     * MEDIA_PLAY_FROM_SEARCH — the Android "play this" intent that YouTube Music
     * and Spotify start playing straight away (no API key). Focus = song when
     * we know the title, artist when only the artist is known.
     */
    private fun playFromSearch(
        activity: Activity, pkg: String, query: String, artist: String?, title: String?
    ): String {
        if (pkg.isBlank()) return "no_app"
        return try {
            val i = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH)
                .setPackage(pkg)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(SearchManager.QUERY, query)
            when {
                !title.isNullOrBlank() -> {
                    i.putExtra(MediaStore.EXTRA_MEDIA_FOCUS, MediaStore.Audio.Media.ENTRY_CONTENT_TYPE)
                    i.putExtra(MediaStore.EXTRA_MEDIA_TITLE, title)
                    if (!artist.isNullOrBlank()) i.putExtra(MediaStore.EXTRA_MEDIA_ARTIST, artist)
                }
                !artist.isNullOrBlank() -> {
                    i.putExtra(MediaStore.EXTRA_MEDIA_FOCUS, MediaStore.Audio.Artists.ENTRY_CONTENT_TYPE)
                    i.putExtra(MediaStore.EXTRA_MEDIA_ARTIST, artist)
                }
                else -> i.putExtra(MediaStore.EXTRA_MEDIA_FOCUS, "vnd.android.cursor.item/*")
            }
            activity.startActivity(i)
            "ok"
        } catch (ignored: android.content.ActivityNotFoundException) {
            "no_app"
        } catch (ignored: Throwable) {
            "error"
        }
    }

    private fun openYoutubeVideo(activity: Activity, id: String): Boolean {
        if (!Regex("^[A-Za-z0-9_-]{6,20}$").matches(id)) return false
        return try {
            activity.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("vnd.youtube:$id"))
                    .setPackage("com.google.android.youtube")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (ignored: Throwable) {
            false
        }
    }

    // ---- default assistant ---------------------------------------------------

    private fun isDefaultAssistant(ctx: Context): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val rm = ctx.getSystemService(RoleManager::class.java) ?: return null
            if (!rm.isRoleAvailable(RoleManager.ROLE_ASSISTANT)) return null
            rm.isRoleHeld(RoleManager.ROLE_ASSISTANT)
        } catch (ignored: Exception) {
            null
        }
    }

    private fun openAssistantSettings(activity: Activity): Boolean {
        // 1) "Default digital assistant app" (most phones incl. ColorOS),
        // 2) the Default-apps list, 3) plain Settings.
        val tries = listOf(
            Intent(Settings.ACTION_VOICE_INPUT_SETTINGS),
            Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
            Intent(Settings.ACTION_SETTINGS)
        )
        for (i in tries) {
            if (startSafely(activity, i)) return true
        }
        return false
    }

    private fun startSafely(activity: Activity, intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (ignored: Exception) {
        false
    }

    // ---- TTS -------------------------------------------------------------------

    private fun pickLocale(t: TextToSpeech, lang: String): Locale? {
        val cands = if (lang == "bn") {
            listOf(Locale("bn", "BD"), Locale("bn", "IN"), Locale("bn"))
        } else {
            listOf(Locale.US, Locale.UK, Locale("en", "IN"), Locale.ENGLISH)
        }
        for (l in cands) {
            try {
                if (t.isLanguageAvailable(l) >= TextToSpeech.LANG_AVAILABLE) return l
            } catch (ignored: Exception) {}
        }
        return null
    }

    private fun speak(ctx: Context, text: String, lang: String, result: MethodChannel.Result) {
        if (text.isBlank()) { result.success("ok"); return }
        val doSpeak: () -> Unit = {
            try {
                val t = tts
                if (t == null || !ttsReady) {
                    result.success("no_engine")
                } else {
                    val loc = pickLocale(t, lang)
                    if (loc == null) {
                        result.success("no_voice")
                    } else {
                        t.language = loc
                        // Answer Dart only when the utterance has finished (or
                        // was flushed), so the confirm sheet can listen for a
                        // spoken "yes" without hearing its own question.
                        val id = "va-" + (++utterSeq)
                        flushPending()
                        pending[id] = result
                        if (t.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) != TextToSpeech.SUCCESS) {
                            pending.remove(id)
                            result.success("no_engine")
                        }
                    }
                }
            } catch (ignored: Exception) {
                try { result.success("no_engine") } catch (ignored: Exception) {}
            }
        }
        if (tts != null && ttsReady) { doSpeak(); return }
        if (tts != null) { pendingSpeak = doSpeak; return }
        try {
            pendingSpeak = doSpeak
            tts = TextToSpeech(ctx.applicationContext) { status ->
                ttsReady = status == TextToSpeech.SUCCESS
                try { tts?.setOnUtteranceProgressListener(progress) } catch (ignored: Exception) {}
                val p = pendingSpeak
                pendingSpeak = null
                p?.invoke()
            }
        } catch (ignored: Exception) {
            pendingSpeak = null
            result.success("no_engine")
        }
    }

    // ---- torch -----------------------------------------------------------------

    private fun torch(ctx: Context, on: Boolean): String {
        return try {
            val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val id = cm.cameraIdList.firstOrNull { cid ->
                cm.getCameraCharacteristics(cid)
                    .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
            } ?: return "no_flash"
            cm.setTorchMode(id, on)
            "ok"
        } catch (ignored: Exception) {
            "error"
        }
    }

    // ---- alarm / timer ---------------------------------------------------------

    private fun setAlarm(activity: Activity, hour: Int?, minute: Int?, label: String): String {
        val i = Intent(AlarmClock.ACTION_SET_ALARM).putExtra(AlarmClock.EXTRA_MESSAGE, label)
        if (hour != null) {
            i.putExtra(AlarmClock.EXTRA_HOUR, hour)
            i.putExtra(AlarmClock.EXTRA_MINUTES, minute ?: 0)
            // Show the clock app's confirmation UI rather than silently setting.
            i.putExtra(AlarmClock.EXTRA_SKIP_UI, false)
        }
        return startClock(activity, i)
    }

    private fun setTimer(activity: Activity, seconds: Int?, label: String): String {
        val i = Intent(AlarmClock.ACTION_SET_TIMER).putExtra(AlarmClock.EXTRA_MESSAGE, label)
        if (seconds != null && seconds > 0) {
            i.putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            i.putExtra(AlarmClock.EXTRA_SKIP_UI, false)
        }
        return startClock(activity, i)
    }

    private fun startClock(activity: Activity, i: Intent): String = try {
        activity.startActivity(i)
        "ok"
    } catch (ignored: SecurityException) {
        "denied" // SET_ALARM permission missing from the manifest
    } catch (ignored: Exception) {
        "no_app"
    }

    // ---- apps ------------------------------------------------------------------

    private fun listApps(ctx: Context): List<Map<String, String>> {
        return try {
            val pm = ctx.packageManager
            val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            pm.queryIntentActivities(main, 0).mapNotNull { ri ->
                try {
                    mapOf(
                        "label" to ri.loadLabel(pm).toString(),
                        "package" to ri.activityInfo.packageName
                    )
                } catch (ignored: Exception) { null }
            }.distinctBy { it["package"] }
        } catch (ignored: Exception) {
            emptyList()
        }
    }

    private fun launchApp(activity: Activity, pkg: String): Boolean {
        if (pkg.isBlank()) return false
        return try {
            val i = activity.packageManager.getLaunchIntentForPackage(pkg) ?: return false
            activity.startActivity(i)
            true
        } catch (ignored: Exception) {
            false
        }
    }

    private fun youtubeSearch(activity: Activity, q: String): Boolean = try {
        val i = Intent(Intent.ACTION_SEARCH)
            .setPackage("com.google.android.youtube")
            .putExtra("query", q)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(i)
        true
    } catch (ignored: Exception) {
        false
    }

    // ---- contacts / call -------------------------------------------------------

    private fun contacts(ctx: Context): List<Map<String, String>> {
        if (ctx.checkSelfPermission(Manifest.permission.READ_CONTACTS)
            != PackageManager.PERMISSION_GRANTED) return emptyList()
        val out = ArrayList<Map<String, String>>()
        try {
            ctx.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER
                ),
                null, null, null
            )?.use { c ->
                val ni = c.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val pi = c.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                while (c.moveToNext() && out.size < 5000) {
                    val n = if (ni >= 0) c.getString(ni) ?: "" else ""
                    val p = if (pi >= 0) c.getString(pi) ?: "" else ""
                    if (n.isNotBlank() && p.isNotBlank()) out.add(mapOf("name" to n, "phone" to p))
                }
            }
        } catch (ignored: Exception) {}
        return out
    }

    private fun callNow(activity: Activity, number: String): String {
        if (number.isBlank()) return "error"
        if (activity.checkSelfPermission(Manifest.permission.CALL_PHONE)
            != PackageManager.PERMISSION_GRANTED) return "denied"
        return try {
            activity.startActivity(Intent(Intent.ACTION_CALL, Uri.parse("tel:" + Uri.encode(number))))
            "ok"
        } catch (ignored: SecurityException) {
            "denied"
        } catch (ignored: Exception) {
            "error"
        }
    }
}
