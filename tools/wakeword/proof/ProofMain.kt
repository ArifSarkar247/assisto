// wakeword (4 Nov): runs the PHONE's engine (OwwEngine.kt + WakeDecider, the
// exact Kotlin the app ships) with the SHIPPED model files on synthetic clips,
// in the phone's 80 ms chunks, and measures CPU time per second of audio.
// usage: ProofMain <model dir> <clips dir> <out.json>
// clips: *.raw = 16 kHz mono int16 LE; name starts with "pos_" or "neg_".
import com.assisto.assisto.voice.OwwEngine
import com.assisto.assisto.voice.WakeDecider
import org.json.JSONObject
import java.io.File
import java.lang.management.ManagementFactory
import java.nio.ByteBuffer
import java.nio.ByteOrder

fun main(args: Array<String>) {
    val dir = File(args[0])
    val m = JSONObject(File(dir, "manifest.json").readText())
    val files = HashMap<String, String>()
    val fa = m.getJSONArray("files")
    for (i in 0 until fa.length()) {
        val f = fa.getJSONObject(i)
        files[f.getString("role")] = File(dir, f.getString("name")).path
    }
    val th = m.getJSONObject("thresholds")
    val levels = listOf("low", "normal", "high")
    val engine = OwwEngine(m.optString("feature_backend", "e2e"), files,
        m.optInt("window_samples", 12400), m.optInt("frames", 16))
    val bean = ManagementFactory.getThreadMXBean()
    val out = JSONObject()
    val clips = JSONObject()
    var audioSec = 0.0
    var cpuNs = 0L
    for (clip in File(args[1]).listFiles()!!.filter { it.name.endsWith(".raw") }.sortedBy { it.name }) {
        val b = clip.readBytes()
        val sb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val pcm = ShortArray(sb.remaining()); sb.get(pcm)
        engine.reset()
        val deciders = levels.associateWith {
            WakeDecider(th.getDouble(it).toFloat(), WakeDecider.patienceFor(it))
        }
        val hits = levels.associateWith { 0 }.toMutableMap()
        var maxScore = 0f
        var frame = 0L
        val t0 = bean.currentThreadCpuTime
        var i = 0
        while (i < pcm.size) {
            val n = minOf(OwwEngine.HOP, pcm.size - i)
            engine.push(pcm.copyOfRange(i, i + n), n) { s ->
                frame++
                if (s > maxScore) maxScore = s
                for (l in levels) if (deciders[l]!!.feed(s, frame * 80)) hits[l] = hits[l]!! + 1
            }
            i += n
        }
        cpuNs += bean.currentThreadCpuTime - t0
        audioSec += pcm.size / 16000.0
        clips.put(clip.name, JSONObject().put("max_score", maxScore.toDouble())
            .put("low", hits["low"]).put("normal", hits["normal"]).put("high", hits["high"]))
    }
    out.put("clips", clips)
    out.put("audio_seconds", audioSec)
    out.put("cpu_ms_per_audio_second", cpuNs / 1e6 / audioSec)
    out.put("thresholds", th)
    File(args[2]).writeText(out.toString(1))
    println(out.toString(1))
}
