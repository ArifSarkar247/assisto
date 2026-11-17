package com.assisto.assisto.train

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.telephony.CellIdentityGsm
import android.telephony.CellIdentityLte
import android.telephony.CellIdentityNr
import android.telephony.CellIdentityWcdma
import android.telephony.CellInfo
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoWcdma
import android.telephony.TelephonyManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * train-app (Train Tracker V2) "com.assisto/train_v2":
 *
 *   servingCell()          -> Map?   the phone's SERVING cell {mcc, mnc, tac, cid,
 *                                    rat, dbm} from TelephonyManager.getAllCellInfo.
 *                                    Needs ONLY ACCESS_FINE_LOCATION, which the
 *                                    rider already granted for the trip (the
 *                                    app declares it for Safe Journey). No
 *                                    READ_PHONE_STATE. Null when not granted,
 *                                    no SIM, airplane mode or any error.
 *   power()                -> Map    {pct, charging} from the sticky battery
 *                                    broadcast (no permission).
 *   setShareTarget(on)     -> Bool   enables / disables the "Share to Assisto"
 *                                    text target (TrainShareActivity). It is
 *                                    DISABLED in the manifest and only switched
 *                                    on while the Train Tracker flag is on.
 *   takeSharedText()       -> String? text shared from the SMS app (the 16318
 *                                    reply), read once then cleared.
 *
 * Lazy and crash-guarded: registering costs nothing; every call answers
 * null / false instead of throwing. Nothing runs at launch.
 */
object TrainV2Channel {
    private const val NAME = "com.assisto/train_v2"

    @Volatile
    var pendingText: String? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "servingCell" -> result.success(servingCell(app))
                "power" -> result.success(power(app))
                "setShareTarget" -> result.success(setShareTarget(app, call.argument<Boolean>("on") ?: false))
                "takeSharedText" -> {
                    val v = pendingText
                    pendingText = null
                    result.success(v)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun servingCell(app: Context): Map<String, Any?>? {
        return try {
            if (app.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) !=
                PackageManager.PERMISSION_GRANTED
            ) return null
            val tm = app.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return null
            @Suppress("MissingPermission")
            val all: List<CellInfo> = tm.allCellInfo ?: return null
            val c = all.firstOrNull { it.isRegistered } ?: return null
            cellMap(c)
        } catch (e: Throwable) {
            null
        }
    }

    private val new28: Boolean get() = Build.VERSION.SDK_INT >= 28

    // API 26-27: the deprecated Int getters (Int.MAX_VALUE = unknown)
    private fun old(v: Int): String? = if (v == Int.MAX_VALUE || v < 0) null else v.toString()

    @Suppress("DEPRECATION")
    private fun cellMap(c: CellInfo): Map<String, Any?>? {
        return when (c) {
            is CellInfoLte -> {
                val id: CellIdentityLte = c.cellIdentity
                mapOf(
                    "rat" to "lte", "mcc" to (if (new28) id.mccString else old(id.mcc)), "mnc" to (if (new28) id.mncString else old(id.mnc)),
                    "tac" to id.tac, "cid" to id.ci, "dbm" to c.cellSignalStrength.dbm
                )
            }
            is CellInfoGsm -> {
                val id: CellIdentityGsm = c.cellIdentity
                mapOf(
                    "rat" to "gsm", "mcc" to (if (new28) id.mccString else old(id.mcc)), "mnc" to (if (new28) id.mncString else old(id.mnc)),
                    "tac" to id.lac, "cid" to id.cid, "dbm" to c.cellSignalStrength.dbm
                )
            }
            is CellInfoWcdma -> {
                val id: CellIdentityWcdma = c.cellIdentity
                mapOf(
                    "rat" to "wcdma", "mcc" to (if (new28) id.mccString else old(id.mcc)), "mnc" to (if (new28) id.mncString else old(id.mnc)),
                    "tac" to id.lac, "cid" to id.cid, "dbm" to c.cellSignalStrength.dbm
                )
            }
            else -> {
                if (Build.VERSION.SDK_INT >= 29 && c is CellInfoNr) {
                    val id = c.cellIdentity as CellIdentityNr
                    mapOf(
                        "rat" to "nr", "mcc" to id.mccString, "mnc" to id.mncString,
                        "tac" to id.tac, "cid" to id.nci, "dbm" to c.cellSignalStrength.dbm
                    )
                } else null
            }
        }?.let { m ->
            // unknown fields come back as Int.MAX_VALUE / null: drop the cell
            val cid = (m["cid"] as? Number)?.toLong()
            if (m["mcc"] == null || m["mnc"] == null || cid == null ||
                cid == Int.MAX_VALUE.toLong() || cid == Long.MAX_VALUE || cid <= 0
            ) null else m
        }
    }

    private fun power(app: Context): Map<String, Any?> {
        return try {
            val i = app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val status = i?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val pct = if (level >= 0 && scale > 0) level * 100 / scale else null
            mapOf(
                "pct" to pct,
                "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL)
            )
        } catch (e: Throwable) {
            mapOf("pct" to null, "charging" to false)
        }
    }

    private fun setShareTarget(app: Context, on: Boolean): Boolean {
        return try {
            app.packageManager.setComponentEnabledSetting(
                ComponentName(app, TrainShareActivity::class.java),
                if (on) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
            true
        } catch (e: Throwable) {
            false
        }
    }
}

/**
 * train-app: the "Share to Assisto" target for plain text (the user shares the
 * 16318 SMS reply from their OWN SMS app — Assisto never reads SMS). A
 * translucent trampoline: keeps the text (max 2 000 chars) for Dart and opens
 * Assisto on the "Paste 16318 reply" screen (assisto_open = train_paste).
 * Disabled in the manifest; enabled only while the Train Tracker flag is on.
 */
class TrainShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val i = intent
            if (i?.action == Intent.ACTION_SEND && (i.type ?: "").startsWith("text/")) {
                val text = i.getStringExtra(Intent.EXTRA_TEXT)?.take(2000)
                if (!text.isNullOrBlank()) {
                    TrainV2Channel.pendingText = text
                    startActivity(
                        Intent(this, com.assisto.assisto.MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP)
                            .putExtra("assisto_open", "train_paste")
                    )
                }
            }
        } catch (e: Throwable) {
        }
        finish()
    }
}
