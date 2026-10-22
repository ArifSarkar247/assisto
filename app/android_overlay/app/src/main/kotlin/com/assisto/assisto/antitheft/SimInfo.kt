package com.assisto.assisto.antitheft

import android.content.Context
import android.telephony.TelephonyManager

/**
 * b6-antitheft — honest SIM info.
 *
 * On modern Android a normal app CANNOT read the new SIM's phone number
 * (getLine1Number returns "" or needs a privileged/carrier permission). We
 * therefore NEVER report a phone number from here; we only read the carrier
 * (network operator) name when the OS allows it. The server's alert text is
 * explicit that the number is usually not readable.
 */
object SimInfo {
    fun carrier(ctx: Context): String? {
        return try {
            val tm = ctx.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            val name = tm?.simOperatorName ?: tm?.networkOperatorName
            if (name.isNullOrBlank()) null else name
        } catch (_: Throwable) {
            null
        }
    }
}
