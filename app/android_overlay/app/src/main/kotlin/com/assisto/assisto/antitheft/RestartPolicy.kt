package com.assisto.assisto.antitheft

/**
 * at-heartbeat — PURE rules for bringing the always-on engine back after the
 * system killed it (no Android imports, so the rules are mirrored 1:1 and
 * unit-tested in Dart: app/lib/services/antitheft_logic.dart
 * `RestartRules` + test/at_heartbeat_restart_test.dart).
 *
 * Owner bug (24 Oct): a Play update replaced the app, which kills the
 * foreground service; nothing restarted it, so the family was told the phone
 * "stopped checking in" while the owner was using it.
 *
 * Triggers:
 *   APP     the owner opened / resumed Assisto (foreground): always allowed.
 *   UPDATE  MY_PACKAGE_REPLACED (the app was just updated).
 *   BOOT    BOOT_COMPLETED / QUICKBOOT_POWERON.
 *
 * Android rules this follows (never crash, degrade instead):
 *   * Android 12+ forbids starting a foreground service from the background,
 *     EXCEPT from BOOT_COMPLETED / LOCKED_BOOT_COMPLETED / MY_PACKAGE_REPLACED
 *     (QUICKBOOT_POWERON is NOT exempt -> startForegroundService throws, which
 *     start() catches; the real BOOT_COMPLETED follows anyway).
 *   * Android 14+ checks the foreground-service TYPE when it starts. From the
 *     background a LOCATION type needs ACCESS_BACKGROUND_LOCATION (we never
 *     ask for it), and CAMERA is never allowed from BOOT_COMPLETED. So on
 *     Android 14+ a background restart happens ONLY when background location
 *     is already granted; otherwise we post a "tap to resume" notification
 *     and the engine restarts when the owner opens Assisto (APP).
 *   * A background restart never declares the CAMERA type (the open app
 *     re-declares it). It never re-records the SIM baseline either: the SIM(s)
 *     are COMPARED to the baseline recorded when protection was switched on.
 */
object RestartPolicy {
    const val APP = "app"
    const val UPDATE = "update"
    const val BOOT = "boot"
    // at100: a silent high-priority "at_command" FCM push (a remote switch is
    // waiting). Android 12+ allows a foreground-service start for a
    // high-priority FCM message; Android 14+ still checks the location type.
    const val PUSH = "push"

    /** Start the foreground service now from [trigger]? */
    fun canStart(trigger: String, sdk: Int, hasBackgroundLocation: Boolean): Boolean {
        if (trigger == APP) return true
        if (trigger != UPDATE && trigger != BOOT && trigger != PUSH) return false
        if (sdk >= 34) return hasBackgroundLocation
        return true
    }

    /** May this start declare the CAMERA foreground type? Only from the app. */
    fun allowCamera(trigger: String): Boolean = trigger == APP

    /** Show the "tap to resume protection" notification instead? */
    fun needsTapToResume(trigger: String, sdk: Int, hasBackgroundLocation: Boolean): Boolean =
        (trigger == UPDATE || trigger == BOOT || trigger == PUSH) &&
            !canStart(trigger, sdk, hasBackgroundLocation)
}
