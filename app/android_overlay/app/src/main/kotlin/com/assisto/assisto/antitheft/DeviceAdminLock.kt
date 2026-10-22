package com.assisto.assisto.antitheft

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import com.assisto.assisto.AssistoDeviceAdminReceiver

/**
 * b6-antitheft — lock the screen through the EXISTING device-admin receiver
 * (AssistoDeviceAdminReceiver, force-lock policy). Returns true only if admin
 * is actually active AND the lock succeeded — we never claim a lock we did not
 * perform. Used by the snatch guard's optional instant lock.
 */
object DeviceAdminLock {
    fun isActive(ctx: Context): Boolean = try {
        val dpm = ctx.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        dpm.isAdminActive(ComponentName(ctx, AssistoDeviceAdminReceiver::class.java))
    } catch (_: Throwable) {
        false
    }

    fun lockNow(ctx: Context): Boolean = try {
        val dpm = ctx.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        if (!dpm.isAdminActive(ComponentName(ctx, AssistoDeviceAdminReceiver::class.java))) {
            false
        } else {
            dpm.lockNow()
            true
        }
    } catch (_: Throwable) {
        false
    }
}
