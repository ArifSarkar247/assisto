package com.assisto.assisto

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast
import com.assisto.assisto.antitheft.AntiTheftService
import com.assisto.assisto.antitheft.AntiTheftQueue
import org.json.JSONObject

/**
 * #80 Lost / stolen phone protection — the Device Admin receiver.
 *
 * This is the real, system-recognised DeviceAdminReceiver. The user must
 * explicitly grant device-admin rights on the system consent screen
 * (ACTION_ADD_DEVICE_ADMIN) before ANY of the policies declared in
 * res/xml/device_admin.xml become usable. Nothing here is silent.
 *
 * SCOPE (conservative, Play-policy aware):
 *   - force-lock              (remote lock the screen)
 *   - watch-login             (onPasswordFailed: wrong unlock attempts)
 *   at100: limit-password / reset-password REMOVED — never used, and both
 *   are deprecated for device admins (Android 9/10); minimal Play scope.
 *   NO <wipe-data>. Remote wipe is intentionally NOT requested — see the
 *   PLAY-POLICY note in the integration doc. Add it only if the owner accepts
 *   the anti-theft policy review.
 *
 * While this admin is ACTIVE the OS blocks uninstall of the app until the user
 * deactivates admin (Settings → Security → Device admin apps). That is the
 * uninstall-resistance the feature relies on; it is surfaced honestly to the
 * user in the Dart screen.
 */
class AssistoDeviceAdminReceiver : DeviceAdminReceiver() {

    override fun onEnabled(context: Context, intent: Intent) {
        super.onEnabled(context, intent)
        Toast.makeText(
            context,
            "Assisto device protection enabled",
            Toast.LENGTH_SHORT
        ).show()
    }

    override fun onDisabled(context: Context, intent: Intent) {
        super.onDisabled(context, intent)
        Toast.makeText(
            context,
            "Assisto device protection disabled",
            Toast.LENGTH_SHORT
        ).show()
    }

    /**
     * b6-antitheft — a wrong device-unlock attempt. We QUEUE a failed_unlock
     * event (with the OS's running wrong-attempt count) for the anti-theft
     * engine's store-and-forward queue, and ask the service to flush. The
     * server only alerts family once the count reaches the owner's threshold.
     *
     * at100: NO photo here. The lock screen means Assisto is in the
     * background, where Android does not allow the camera (and we hold no
     * camera foreground-service type). Only the attempt + count is recorded;
     * the intruder photo is taken only while Assisto is open (wrong Security
     * PIN in the app). Fully crash-guarded: an error here must never affect
     * the lock screen.
     */
    override fun onPasswordFailed(context: Context, intent: Intent) {
        super.onPasswordFailed(context, intent)
        try {
            val prefs = context.getSharedPreferences(
                "assisto_antitheft_engine", Context.MODE_PRIVATE)
            if ((prefs.getString("token", "") ?: "").isBlank()) return
            var count = 0
            try {
                val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE)
                        as? android.app.admin.DevicePolicyManager
                count = dpm?.currentFailedPasswordAttempts ?: 0
            } catch (_: Throwable) {
            }
            val q = AntiTheftQueue(context)
            q.add("fail-" + System.currentTimeMillis(), "failed_unlock",
                System.currentTimeMillis(), null, null, null,
                JSONObject().put("count", count))
            AntiTheftService.onFailedUnlock(context, count)
        } catch (_: Throwable) {
            // never disturb the lock screen
        }
    }

    /**
     * Warning text shown by the system on the de-activation confirmation
     * dialog. Keep it honest and short.
     */
    override fun onDisableRequested(context: Context, intent: Intent): CharSequence {
        return "Turning this off removes lost/stolen protection and re-allows " +
            "uninstalling Assisto."
    }
}
