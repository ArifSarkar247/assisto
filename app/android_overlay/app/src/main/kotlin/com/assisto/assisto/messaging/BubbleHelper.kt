package com.assisto.assisto.messaging

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.content.LocusId
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * c3-msg — Android Bubbles (API 30+) for My Circle chats, Messenger-chat-head
 * style but through the Play-compliant Bubbles API (no SYSTEM_ALERT_WINDOW).
 *
 * HOW: Dart (flutter_local_notifications) posts the MessagingStyle
 * conversation notification with tag "c3chat:<kind>:<id>" and shortcut id
 * "c3chat_<kind>_<id>". When a message push arrives, AssistoFcmService calls
 * [onMessagePush]; we wait for that notification to appear (the Dart isolate
 * decrypts first), publish a long-lived conversation shortcut, and re-post
 * the SAME notification (Notification.Builder.recoverBuilder keeps its
 * MessagingStyle and the inline-reply / mark-read actions) with
 * BubbleMetadata → the system shows a floating round avatar; tapping it
 * opens [BubbleActivity] on that chat. Several chats = several bubbles.
 *
 * Gates: Android 11+, the global switch `flutter.c3_bubbles_on` (default on)
 * and the per-chat list `flutter.c3_bubble_chats` (FlutterSharedPreferences,
 * written by Dart MsgPrefs), plus the user's own system bubble setting.
 * Everything is try/catch: a bubble failure never affects the notification.
 */
object BubbleHelper {
    private const val TAG = "AssistoBubble"
    private const val PREFS = "FlutterSharedPreferences"
    private val DELAYS_MS = longArrayOf(700, 1500, 2600, 4200, 6500, 10000)

    fun chatKey(kind: String, id: String) = "${if (kind == "group") "group" else "member"}:$id"
    fun tagFor(kind: String, id: String) = "c3chat:${if (kind == "group") "group" else "member"}:$id"
    fun shortcutIdFor(kind: String, id: String) = "c3chat_${if (kind == "group") "group" else "member"}_$id"

    fun enabledFor(context: Context, key: String): Boolean {
        return try {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val global = if (p.contains("flutter.c3_bubbles_on")) p.getBoolean("flutter.c3_bubbles_on", true) else true
            if (!global) return false
            val chats = p.getString("flutter.c3_bubble_chats", "") ?: ""
            chats.split(",").map { it.trim() }.contains(key)
        } catch (t: Throwable) {
            false
        }
    }

    /** Called from the FCM service for every data push (any thread). */
    fun onMessagePush(context: Context, data: Map<String, String>) {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
            if (data["kind"] != "message") return
            val kind = if (data["chat_kind"] == "group") "group" else "member"
            val id = data["chat_id"]?.trim().orEmpty()
            if (id.isEmpty()) return
            val app = context.applicationContext
            if (!enabledFor(app, chatKey(kind, id))) return
            val h = Handler(Looper.getMainLooper())
            var done = false
            for (d in DELAYS_MS) {
                h.postDelayed({
                    if (!done) done = attach(app, kind, id, data["sender_name"].orEmpty())
                }, d)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "bubble schedule skipped: ${t.javaClass.simpleName}")
        }
    }

    /** Re-post the active conversation notification with bubble metadata.
     *  Returns true when there is nothing more to do (attached or gone). */
    fun attach(context: Context, kind: String, id: String, fallbackName: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true
        return try {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return true
            // Until the manifest entry lands (proposal c3-msg), skip quietly.
            if (!bubbleActivityDeclared(context)) return true
            val tag = tagFor(kind, id)
            val sbn = nm.activeNotifications.firstOrNull { it.tag == tag } ?: return false
            val n = sbn.notification
            if (n.bubbleMetadata != null) return true
            val title = (n.extras?.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
                ?: n.extras?.getCharSequence(Notification.EXTRA_TITLE))?.toString()
                ?.takeIf { it.isNotBlank() } ?: fallbackName.ifBlank { "Assisto" }
            val scId = shortcutIdFor(kind, id)
            val icon = avatarIcon(context)
            publishShortcut(context, scId, kind, id, title, icon)
            val intent = Intent(context, BubbleActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .putExtra(EXTRA_CHAT, chatKey(kind, id))
            val pi = PendingIntent.getActivity(
                context, id.hashCode() xor kind.hashCode(), intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )
            val meta = Notification.BubbleMetadata.Builder(pi, icon)
                .setDesiredHeight(640)
                .setAutoExpandBubble(false)
                .setSuppressNotification(false)
                .build()
            val rebuilt = Notification.Builder.recoverBuilder(context, n)
                .setShortcutId(scId)
                .setLocusId(LocusId(scId))
                .setBubbleMetadata(meta)
                .setOnlyAlertOnce(true)
                .build()
            nm.notify(tag, sbn.id, rebuilt)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "bubble attach skipped: ${t.javaClass.simpleName}")
            true
        }
    }

    private fun bubbleActivityDeclared(context: Context): Boolean = try {
        context.packageManager.getActivityInfo(
            android.content.ComponentName(context, BubbleActivity::class.java), 0
        )
        true
    } catch (t: Throwable) {
        false
    }

    private fun avatarIcon(context: Context): Icon {
        val res = context.resources.getIdentifier("c3_person_avatar", "drawable", context.packageName)
        return if (res != 0) Icon.createWithResource(context, res)
        else Icon.createWithResource(context, android.R.drawable.sym_action_chat)
    }

    private fun publishShortcut(context: Context, scId: String, kind: String, id: String, title: String, icon: Icon) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            val sm = context.getSystemService(ShortcutManager::class.java) ?: return
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(Intent.ACTION_MAIN)
            launch.action = Intent.ACTION_VIEW
            launch.putExtra(EXTRA_CHAT, chatKey(kind, id))
            val person = Person.Builder().setName(title).setKey(scId).setIcon(icon).build()
            val sc = ShortcutInfo.Builder(context, scId)
                .setShortLabel(title.take(24))
                .setLongLabel(title)
                .setIcon(icon)
                .setIntent(launch)
                .setLongLived(true)
                .setPerson(person)
                .setLocusId(LocusId(scId))
                .setCategories(setOf("com.assisto.category.CHAT"))
                .build()
            sm.pushDynamicShortcut(sc)
        } catch (t: Throwable) {
            Log.w(TAG, "shortcut skipped: ${t.javaClass.simpleName}")
        }
    }

    fun removeChat(context: Context, key: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            val i = key.indexOf(':')
            if (i <= 0) return
            val scId = shortcutIdFor(key.substring(0, i), key.substring(i + 1))
            context.getSystemService(ShortcutManager::class.java)
                ?.removeLongLivedShortcuts(listOf(scId))
        } catch (t: Throwable) {
        }
    }

    const val EXTRA_CHAT = "c3_chat"
}
