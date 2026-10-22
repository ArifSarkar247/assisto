package com.assisto.assisto.legal

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle

/**
 * l1-launch — Health Connect privacy-policy entry point.
 *
 * Health Connect REQUIRES the app to declare an activity that handles
 * `androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE` (Android 13 and older)
 * and, on Android 14+, an activity-alias for `VIEW_PERMISSION_USAGE` +
 * `HEALTH_PERMISSIONS`. Without it Health Connect refuses to show the
 * permission dialog. The system opens this when the user taps "privacy
 * policy" on that dialog.
 *
 * It only opens https://lifeassisto.com/privacy (health section) in the
 * browser and finishes — no UI, no Flutter engine, nothing at app launch.
 * Fully crash-guarded: a phone with no browser simply closes this screen.
 * Manifest registration: .phaseB/proposals/l1-launch.md (part C).
 */
class PrivacyPolicyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val lang = try {
                if (resources.configuration.locales[0].language == "bn") "" else "?lang=en"
            } catch (_: Throwable) { "" }
            val uri = Uri.parse("https://lifeassisto.com/privacy$lang#perm-health")
            startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Throwable) {
            // no browser / blocked intent: nothing else to do
        }
        finish()
    }
}
