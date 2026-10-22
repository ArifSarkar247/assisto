package com.assisto.assisto.antitheft

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject

/**
 * b6-antitheft — store-and-forward queue, backed by a tiny private SQLite DB.
 *
 * The engine captures events whether or not the phone is online; they live
 * here (deduped by a stable client id, capped, oldest dropped) until the
 * server accepts them, then they are deleted. Mirrors
 * app/lib/services/antitheft_logic.StoreAndForwardQueue. Every call is
 * try/catch — a storage error must never crash the foreground service.
 */
class AntiTheftQueue(ctx: Context) : SQLiteOpenHelper(ctx.applicationContext, DB, null, 1) {

    companion object {
        private const val DB = "assisto_antitheft.db"
        private const val MAX_ROWS = 500
        private const val PHOTO_DIR = "antitheft_photos"
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS q(" +
                "cid TEXT PRIMARY KEY, kind TEXT, at INTEGER, " +
                "lat REAL, lng REAL, battery INTEGER, data TEXT, photo TEXT)"
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) {}

    /** Queue one event. A repeated cid is ignored (idempotent capture). */
    fun add(
        cid: String, kind: String, atMs: Long,
        lat: Double?, lng: Double?, battery: Int?,
        data: JSONObject = JSONObject(), photoPath: String? = null
    ) {
        try {
            val cv = ContentValues().apply {
                put("cid", cid)
                put("kind", kind)
                put("at", atMs)
                if (lat != null) put("lat", lat)
                if (lng != null) put("lng", lng)
                if (battery != null) put("battery", battery)
                put("data", data.toString())
                if (photoPath != null) put("photo", photoPath)
            }
            writableDatabase.insertWithOnConflict(
                "q", null, cv, SQLiteDatabase.CONFLICT_IGNORE
            )
            trim()
        } catch (_: Throwable) {
        }
    }

    private fun trim() {
        try {
            writableDatabase.execSQL(
                "DELETE FROM q WHERE cid NOT IN " +
                    "(SELECT cid FROM q ORDER BY at DESC LIMIT $MAX_ROWS)"
            )
        } catch (_: Throwable) {
        }
    }

    data class Row(
        val cid: String, val kind: String, val at: Long,
        val lat: Double?, val lng: Double?, val battery: Int?,
        val data: String, val photo: String?
    )

    /** Oldest-first batch of non-photo events as a JSON items array. */
    fun batchJson(limit: Int = 100): JSONArray {
        val arr = JSONArray()
        try {
            readableDatabase.rawQuery(
                "SELECT cid,kind,at,lat,lng,battery,data FROM q " +
                    "WHERE photo IS NULL ORDER BY at ASC LIMIT $limit", null
            ).use { c ->
                while (c.moveToNext()) {
                    val o = JSONObject()
                    o.put("id", c.getString(0))
                    o.put("kind", c.getString(1))
                    o.put("at", c.getLong(2))
                    if (!c.isNull(3)) o.put("lat", c.getDouble(3))
                    if (!c.isNull(4)) o.put("lng", c.getDouble(4))
                    if (!c.isNull(5)) o.put("battery", c.getInt(5))
                    val d = c.getString(6)
                    if (!d.isNullOrEmpty()) {
                        try { o.put("data", JSONObject(d)) } catch (_: Throwable) {}
                    }
                    arr.put(o)
                }
            }
        } catch (_: Throwable) {
        }
        return arr
    }

    /** Oldest queued photo event (cid + file path), or null. */
    fun nextPhoto(): Pair<String, String>? {
        try {
            readableDatabase.rawQuery(
                "SELECT cid,photo FROM q WHERE photo IS NOT NULL " +
                    "ORDER BY at ASC LIMIT 1", null
            ).use { c ->
                if (c.moveToNext()) return Pair(c.getString(0), c.getString(1))
            }
        } catch (_: Throwable) {
        }
        return null
    }

    /** Oldest queued photo event as a full row (for the multipart upload). */
    fun nextPhotoRow(): Row? {
        try {
            readableDatabase.rawQuery(
                "SELECT cid,kind,at,lat,lng,battery,data,photo FROM q " +
                    "WHERE photo IS NOT NULL ORDER BY at ASC LIMIT 1", null
            ).use { c ->
                if (c.moveToNext()) {
                    return Row(
                        c.getString(0), c.getString(1), c.getLong(2),
                        if (c.isNull(3)) null else c.getDouble(3),
                        if (c.isNull(4)) null else c.getDouble(4),
                        if (c.isNull(5)) null else c.getInt(5),
                        c.getString(6) ?: "{}", c.getString(7)
                    )
                }
            }
        } catch (_: Throwable) {
        }
        return null
    }

    /** Delete rows the server accepted or already had. */
    fun ack(cids: Collection<String>) {
        if (cids.isEmpty()) return
        try {
            val db = writableDatabase
            db.beginTransaction()
            try {
                for (cid in cids) {
                    // delete photo file too, if any
                    db.rawQuery("SELECT photo FROM q WHERE cid=?", arrayOf(cid)).use { c ->
                        if (c.moveToNext() && !c.isNull(0)) {
                            try { java.io.File(c.getString(0)).delete() } catch (_: Throwable) {}
                        }
                    }
                    db.delete("q", "cid=?", arrayOf(cid))
                }
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
        } catch (_: Throwable) {
        }
    }

    fun count(): Int {
        return try {
            readableDatabase.rawQuery("SELECT COUNT(*) FROM q", null).use { c ->
                if (c.moveToNext()) c.getInt(0) else 0
            }
        } catch (_: Throwable) {
            0
        }
    }
}
