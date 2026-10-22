// Kotlin/JVM parity check: runs the phone's OwwEngine.kt on the fixture audio
// in irregular chunk sizes and writes one score per 80 ms frame.
// usage: ParityMain <work> e2e            (fake e2e extractor from the fixture)
//        ParityMain <work> oww <dir>      (melspectrogram.onnx + embedding_model.onnx)
import com.assisto.assisto.voice.OwwEngine
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

fun main(args: Array<String>) {
    val w = args[0]
    val b = File("$w/audio.raw").readBytes()
    val sb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
    val pcm = ShortArray(sb.remaining()); sb.get(pcm)
    val wake = "$w/model/assisto_wake.onnx"
    val eng = if (args[1] == "oww") {
        OwwEngine("oww", mapOf("mel" to args[2] + "/melspectrogram.onnx",
            "embed" to args[2] + "/embedding_model.onnx", "wake" to wake), 12400, 16)
    } else {
        OwwEngine("e2e", mapOf("e2e" to "$w/features/fake_e2e.onnx", "wake" to wake), 2560, 16)
    }
    val out = ArrayList<Float>()
    val sizes = intArrayOf(1000, 1280, 77, 3000, 640)
    var i = 0; var k = 0
    while (i < pcm.size) {
        val n = minOf(sizes[k++ % sizes.size], pcm.size - i)
        eng.push(pcm.copyOfRange(i, i + n), n) { out.add(it) }
        i += n
    }
    File("$w/kotlin_${args[1]}.txt").writeText(out.joinToString("\n"))
    println("kotlin ${out.size} scores")
}
