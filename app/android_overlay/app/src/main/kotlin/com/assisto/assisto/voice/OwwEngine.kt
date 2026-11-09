package com.assisto.assisto.voice

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.File
import java.io.FileInputStream
import java.nio.FloatBuffer
import java.security.MessageDigest

/**
 * k1-wake — on-device "Hey Assisto" detector (openWakeWord recipe, our own
 * model). Pure compute: no Android APIs, no threads, so it is easy to reason
 * about and mirrors tools/wakeword/ww/features.py + detector.py EXACTLY
 * (the numbers in the CI evaluation report are the numbers this code gets).
 *
 * Every HOP (1280 samples = 80 ms of 16 kHz audio):
 *   backend "oww": mel model on the last 1760 samples (int16-range floats)
 *                  -> 8 new 32-bin frames (x/10 + 2) -> embedding model on the
 *                  last 76 frames -> one 96-d embedding
 *   backend "e2e": one model on the last [windowSamples] samples ([-1, 1])
 *                  -> one 96-d embedding
 *   classifier on the last [frames] (16) embeddings -> score 0..1
 *   [WakeDecider]: threshold + patience + cooldown -> wake / no wake
 *
 * Construction loads ONNX Runtime + the models (call it on the audio thread,
 * never at app launch). Everything throws on bad input; the service catches.
 */
class OwwEngine(
    backend: String,
    files: Map<String, String>,
    private val windowSamples: Int,
    private val frames: Int,
) : AutoCloseable {

    companion object {
        const val HOP = 1280
        private const val MEL_CONTEXT = 480
        private const val MEL_WINDOW = 76
        private const val MEL_BINS = 32
        private const val EMB = 96

        /** sha256 of a file (hex). Used to verify downloaded models. */
        fun sha256(path: String): String {
            val md = MessageDigest.getInstance("SHA-256")
            FileInputStream(File(path)).use { ins ->
                val buf = ByteArray(1 shl 16)
                while (true) {
                    val n = ins.read(buf)
                    if (n <= 0) break
                    md.update(buf, 0, n)
                }
            }
            return md.digest().joinToString("") { "%02x".format(it) }
        }
    }

    private val e2e = backend == "e2e"
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val opts = OrtSession.SessionOptions().apply {
        setIntraOpNumThreads(1) // one core: background work must stay light
        setInterOpNumThreads(1)
        setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
    }
    private val mel: OrtSession? = if (e2e) null else env.createSession(files.getValue("mel"), opts)
    private val emb: OrtSession = env.createSession(
        if (e2e) files.getValue("e2e") else files.getValue("embed"), opts
    )
    private val wake: OrtSession = env.createSession(files.getValue("wake"), opts)
    private val melIn = mel?.inputNames?.first()
    private val embIn = emb.inputNames.first()
    private val wakeIn = wake.inputNames.first()

    // rolling raw audio the feature model looks at
    private val audioLen = if (e2e) windowSamples else MEL_CONTEXT + HOP
    private val audio = FloatArray(audioLen)
    private var seen = 0L
    // rolling mel frames (oww) and embeddings
    private val melBuf = FloatArray(MEL_WINDOW * 2 * MEL_BINS)
    private var melCount = 0
    private val embBuf = FloatArray(frames * EMB)
    private var embCount = 0
    private val pending = FloatArray(HOP)
    private var pendingN = 0

    fun reset() {
        audio.fill(0f); seen = 0; melCount = 0; embCount = 0; pendingN = 0
        melBuf.fill(0f); embBuf.fill(0f)
    }

    /**
     * Feed 16-bit PCM. Calls [onScore] once per completed 80 ms frame that
     * has a full [frames]-embedding history.
     */
    fun push(pcm: ShortArray, n: Int, onScore: (Float) -> Unit) {
        var i = 0
        while (i < n) {
            val take = minOf(HOP - pendingN, n - i)
            for (k in 0 until take) pending[pendingN + k] = pcm[i + k] / 32768f
            pendingN += take
            i += take
            if (pendingN == HOP) {
                pendingN = 0
                val s = step(pending)
                if (s != null) onScore(s)
            }
        }
    }

    private fun step(chunk: FloatArray): Float? {
        System.arraycopy(audio, HOP, audio, 0, audioLen - HOP)
        System.arraycopy(chunk, 0, audio, audioLen - HOP, HOP)
        seen += HOP
        val e = embedding() ?: return null
        System.arraycopy(embBuf, EMB, embBuf, 0, (frames - 1) * EMB)
        System.arraycopy(e, 0, embBuf, (frames - 1) * EMB, EMB)
        embCount++
        if (embCount < frames) return null
        return classify()
    }

    private fun embedding(): FloatArray? {
        if (e2e) {
            if (seen < windowSamples) return null
            return run1(emb, embIn, audio, longArrayOf(1, windowSamples.toLong()))
        }
        val x = FloatArray(audioLen) { audio[it] * 32767f }
        val m = run1(mel!!, melIn!!, x, longArrayOf(1, audioLen.toLong()))
        val nNew = m.size / MEL_BINS
        val cap = melBuf.size / MEL_BINS
        for (f in 0 until nNew) {
            System.arraycopy(melBuf, MEL_BINS, melBuf, 0, (cap - 1) * MEL_BINS)
            for (b in 0 until MEL_BINS) {
                melBuf[(cap - 1) * MEL_BINS + b] = m[f * MEL_BINS + b] / 10f + 2f
            }
        }
        melCount += nNew
        if (melCount < MEL_WINDOW) return null
        val win = FloatArray(MEL_WINDOW * MEL_BINS)
        System.arraycopy(melBuf, (cap - MEL_WINDOW) * MEL_BINS, win, 0, win.size)
        val out = run1(emb, embIn, win, longArrayOf(1, MEL_WINDOW.toLong(), MEL_BINS.toLong(), 1))
        return out.copyOfRange(out.size - EMB, out.size)
    }

    private fun classify(): Float {
        val out = run1(wake, wakeIn, embBuf, longArrayOf(1, frames.toLong(), EMB.toLong()))
        return out[0]
    }

    private fun run1(s: OrtSession, name: String, data: FloatArray, shape: LongArray): FloatArray {
        OnnxTensor.createTensor(env, FloatBuffer.wrap(data), shape).use { t ->
            s.run(mapOf(name to t)).use { r ->
                val v = r.get(0) as OnnxTensor
                val fb = v.floatBuffer
                val a = FloatArray(fb.remaining())
                fb.get(a)
                return a
            }
        }
    }

    override fun close() {
        try { wake.close() } catch (ignored: Throwable) {}
        try { emb.close() } catch (ignored: Throwable) {}
        try { mel?.close() } catch (ignored: Throwable) {}
        try { opts.close() } catch (ignored: Throwable) {}
    }
}

/**
 * Trigger rule — keep in sync with tools/wakeword/ww/detector.py and
 * app/lib/voice/va_wake_logic.dart (WakeDecider). Low sensitivity = higher
 * threshold AND 2 frames in a row; a 2 s cooldown stops double triggers.
 */
class WakeDecider(
    private val threshold: Float,
    private val patience: Int,
    private val cooldownMs: Long = 2000,
) {
    private var run = 0
    private var last = Long.MIN_VALUE / 2

    fun reset() { run = 0; last = Long.MIN_VALUE / 2 }

    fun feed(score: Float, nowMs: Long): Boolean {
        run = if (score >= threshold) run + 1 else 0
        if (run >= patience && nowMs - last >= cooldownMs) {
            last = nowMs
            run = 0
            return true
        }
        return false
    }

    companion object {
        fun patienceFor(level: String) = if (level == "low") 2 else 1
    }
}
