package com.assisto.assisto.antitheft

import java.io.File
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * b6-antitheft — intruder-photo encryption, WhatsApp-style: an AES-256-GCM key
 * that lives in the APP SANDBOX (a random 32-byte key file), NOT in the Android
 * Keystore.
 *
 * OWNER RULE (22 Oct): the app must never depend on the Android Keystore — it
 * fails or even HANGS on some ColorOS/MIUI phones, and a hang cannot be caught
 * by try/catch. So the Keystore is not used here at all (not even as an
 * optional wrap: a wrap would re-introduce the hang risk on every photo).
 *
 * Pure JVM (java.io + javax.crypto only, no android.*) so the same code is
 * proven by a desktop JVM test: tools/antitheft_crypto/CryptoCheck.kt.
 *
 * Key handling, never throws:
 *   * key file `<dir>/photo.key` (dir = noBackupFilesDir/assisto_antitheft on
 *     the phone: private to the app and excluded from cloud/device backup);
 *   * missing or wrong-size -> a fresh SecureRandom key is written atomically
 *     (temp file + rename);
 *   * if the key file cannot be written at all (full / read-only storage) the
 *     photo is still encrypted with an in-memory key for this process, so the
 *     capture is never dropped and nothing blocks. (If the process then dies
 *     before the upload, that one photo can't be decrypted and is discarded.)
 *
 * Blob format: [1 byte version=1][12 byte IV][ciphertext + 16 byte GCM tag].
 */
object IntruderCrypto {
    private const val KEY_FILE = "photo.key"
    private const val KEY_LEN = 32
    private const val IV_LEN = 12
    private const val VERSION: Byte = 1

    private val rng = SecureRandom()
    @Volatile private var memoryKey: ByteArray? = null

    /** Load (or create) the sandbox key. Falls back to an in-memory key. */
    @Synchronized
    fun key(dir: File): ByteArray {
        try {
            val f = File(dir, KEY_FILE)
            if (f.isFile) {
                val k = f.readBytes()
                if (k.size == KEY_LEN) return k
            }
            dir.mkdirs()
            val k = ByteArray(KEY_LEN).also { rng.nextBytes(it) }
            val tmp = File(dir, "$KEY_FILE.tmp")
            tmp.writeBytes(k)
            if (!tmp.renameTo(f)) {
                f.delete()
                if (!tmp.renameTo(f)) throw IllegalStateException("rename")
            }
            if (File(dir, KEY_FILE).readBytes().contentEquals(k)) return k
        } catch (_: Throwable) {
        }
        // storage unusable: never drop the photo, use a per-process key
        return memoryKey ?: ByteArray(KEY_LEN).also {
            rng.nextBytes(it)
            memoryKey = it
        }
    }

    /** Encrypt; null only if the JVM has no AES-GCM (never on Android). */
    fun seal(key: ByteArray, plain: ByteArray): ByteArray? = try {
        val iv = ByteArray(IV_LEN).also { rng.nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        val ct = c.doFinal(plain)
        ByteArray(1 + IV_LEN + ct.size).also {
            it[0] = VERSION
            System.arraycopy(iv, 0, it, 1, IV_LEN)
            System.arraycopy(ct, 0, it, 1 + IV_LEN, ct.size)
        }
    } catch (_: Throwable) {
        null
    }

    /** Encrypt with the sandbox key of [dir] (or the in-memory fallback). */
    fun sealIn(dir: File, plain: ByteArray): ByteArray? = seal(key(dir), plain)

    /** Decrypt with the sandbox key, then the in-memory fallback key. */
    fun openIn(dir: File, blob: ByteArray): ByteArray? {
        open(key(dir), blob)?.let { return it }
        val m = memoryKey ?: return null
        return open(m, blob)
    }

    /** Decrypt; null if the blob is corrupt, tampered or from another key. */
    fun open(key: ByteArray, blob: ByteArray): ByteArray? = try {
        if (blob.size < 1 + IV_LEN + 16 || blob[0] != VERSION) {
            null
        } else {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"),
                GCMParameterSpec(128, blob, 1, IV_LEN))
            c.doFinal(blob, 1 + IV_LEN, blob.size - 1 - IV_LEN)
        }
    } catch (_: Throwable) {
        null
    }
}
