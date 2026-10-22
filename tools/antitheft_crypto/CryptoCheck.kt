// b6r: desktop-JVM proof of IntruderCrypto (the intruder-photo encryption that
// replaced the Android Keystore — owner rule 22 Oct). No Android needed:
//   kotlinc app/android_overlay/.../antitheft/IntruderCrypto.kt \
//           tools/antitheft_crypto/CryptoCheck.kt -include-runtime -d cc.jar
//   java -jar cc.jar <empty scratch dir>
// Exit code 0 = every check passed.
import com.assisto.assisto.antitheft.IntruderCrypto
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

var failed = 0
fun check(name: String, ok: Boolean) {
    println((if (ok) "PASS " else "FAIL ") + name)
    if (!ok) failed++
}

fun main(args: Array<String>) {
    val root = File(args[0]).apply { mkdirs() }
    val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte()) +
        ByteArray(5000) { (it * 31).toByte() }

    // 1. sandbox key: created once, 32 bytes, persisted, reused
    val d1 = File(root, "sandbox")
    val k1 = IntruderCrypto.key(d1)
    val kf = File(d1, "photo.key")
    check("key file created with 32 bytes", kf.isFile && kf.length() == 32L)
    check("same key on second load", IntruderCrypto.key(d1).contentEquals(k1))
    check("no temp file left behind", !File(d1, "photo.key.tmp").exists())

    // 2. AES-GCM round trip + tamper / wrong-key rejection
    val blob = IntruderCrypto.sealIn(d1, jpeg)!!
    check("ciphertext is not a JPEG", !(blob[1] == 0xFF.toByte() && blob[2] == 0xD8.toByte()) &&
        blob.size == 1 + 12 + jpeg.size + 16)
    check("round trip decrypts to the JPEG", IntruderCrypto.openIn(d1, blob)!!.contentEquals(jpeg))
    val tampered = blob.copyOf().also { it[40] = (it[40].toInt() xor 1).toByte() }
    check("tampered blob rejected (null, no throw)", IntruderCrypto.openIn(d1, tampered) == null)
    check("wrong key rejected", IntruderCrypto.open(ByteArray(32), blob) == null)
    check("garbage blob rejected", IntruderCrypto.open(k1, byteArrayOf(1, 2, 3)) == null)
    check("two seals use different IVs", !IntruderCrypto.sealIn(d1, jpeg)!!.contentEquals(blob))

    // 3. corrupt (wrong-size) key file -> fresh key, still works
    val d2 = File(root, "corrupt").apply { mkdirs() }
    File(d2, "photo.key").writeBytes(ByteArray(7))
    val k2 = IntruderCrypto.key(d2)
    check("wrong-size key file replaced", k2.size == 32 && File(d2, "photo.key").length() == 32L)
    check("works after replacement",
        IntruderCrypto.openIn(d2, IntruderCrypto.sealIn(d2, jpeg)!!)!!.contentEquals(jpeg))

    // 4. storage unusable (read-only dir) -> in-memory key, photo NOT dropped
    val ro = File(root, "readonly").apply { mkdirs() }
    ro.setWritable(false, false)
    val t0 = System.nanoTime()
    val mk = IntruderCrypto.key(ro)
    val ms = (System.nanoTime() - t0) / 1_000_000
    check("read-only dir: still returns a 32-byte key", mk.size == 32)
    check("read-only dir: no key file written", !File(ro, "photo.key").exists())
    check("read-only dir: did not block (${ms} ms)", ms < 2000)
    val mblob = IntruderCrypto.sealIn(ro, jpeg)
    check("read-only dir: photo still encrypted", mblob != null)
    check("read-only dir: decrypts in the same process",
        IntruderCrypto.openIn(ro, mblob!!)!!.contentEquals(jpeg))
    check("memory key is stable across calls", IntruderCrypto.key(ro).contentEquals(mk))
    // a blob sealed with the memory key still opens via a healthy sandbox dir
    check("memory-key blob opens via openIn on a healthy dir",
        IntruderCrypto.openIn(d1, mblob)!!.contentEquals(jpeg))
    ro.setWritable(true, false)

    // 5. dir path is a FILE (mkdirs impossible) -> fallback, no throw
    val notDir = File(root, "iamafile").apply { writeText("x") }
    check("dir-is-a-file: fallback key, no throw", IntruderCrypto.key(notDir).size == 32)

    // 6. concurrent first use -> one key for everyone
    val d3 = File(root, "race")
    val pool = Executors.newFixedThreadPool(8)
    val futures = (0 until 16).map { pool.submit<ByteArray> { IntruderCrypto.key(d3) } }
    val keys = futures.map { it.get(10, TimeUnit.SECONDS) }
    pool.shutdown()
    check("16 concurrent loads agree on one key", keys.all { it.contentEquals(keys[0]) })
    check("and it is the persisted one", File(d3, "photo.key").readBytes().contentEquals(keys[0]))

    println(if (failed == 0) "ALL PASS" else "$failed FAILED")
    exitProcess(if (failed == 0) 0 else 1)
}
