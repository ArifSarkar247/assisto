package com.assisto.assisto

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast

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
 *   - reset-password          (enforce/reset the device lock when locking)
 *   - watch-login             (so onPasswordFailed can drive a future alarm)
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
     * Warning text shown by the system on the de-activation confirmation
     * dialog. Keep it honest and short.
     */
    override fun onDisableRequested(context: Context, intent: Intent): CharSequence {
        return "Turning this off removes lost/stolen protection and re-allows " +
            "uninstalling Assisto."
    }
}
