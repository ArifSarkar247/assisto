package com.assisto.assisto.itag

/**
 * itag-proof (18 Nov): the iTag link brain in PURE Kotlin (no android.*), so
 * it runs on a plain JVM in CI (tools/itag/ItagEngineTest.kt, workflow
 * itag-proof.yml) with a fake GATT and a virtual clock. ItagChannel.kt is
 * only the thin Android adapter: BluetoothGatt -> [ItagGatt], the main-thread
 * Handler -> [ItagHost.post], MethodChannel -> [ItagHost.emit].
 *
 * Rules it guarantees (each one has a JVM test):
 *  - every GATT step is serialized (one op at a time, its own timeout);
 *  - a write-without-response that never calls back counts as sent (600 ms);
 *  - every connect answers exactly once (true / false), even when it is
 *    replaced, timed out, closed or the radio goes off;
 *  - a fast first failure (Android's famous GATT 133) retries ONCE silently;
 *  - callbacks from an older GATT session are ignored (generation check);
 *  - a stale 15 s connect timer can never close a newer link;
 *  - Bluetooth turned off closes every link with radioOff=true (the app shows
 *    "Bluetooth is off", never a false "left behind" alarm).
 */
enum class ItagService { IMMEDIATE_ALERT, LINK_LOSS }

/** One BLE GATT session with one tag (Android: BluetoothGatt). */
interface ItagGatt {
    fun discoverServices(): Boolean
    /** false = characteristic missing or the write did not start */
    fun writeAlert(service: ItagService, level: Int): Boolean
    fun readBattery(): Boolean
    /** notifications on the button characteristic + its CCCD write */
    fun enableButton(): Boolean
    fun disconnect()
    fun close()
}

/** What the engine needs from the phone. All engine calls run on ONE thread. */
interface ItagHost {
    fun radioOn(): Boolean
    fun canConnect(): Boolean
    fun validAddress(address: String): Boolean
    /** opens a GATT session; its callbacks go to [events] (any thread) */
    fun open(address: String, events: ItagGattEvents): ItagGatt?
    fun post(r: () -> Unit)
    fun postDelayed(ms: Long, r: () -> Unit)
    /** native -> Dart "event" {type, address, user, radioOff} */
    fun emit(type: String, address: String, user: Boolean, radioOff: Boolean)
}

/** GATT callbacks for one session (generation). Safe from any thread. */
class ItagGattEvents internal constructor(
    private val engine: ItagEngine,
    private val link: ItagEngine.Link,
    private val gen: Int,
) {
    fun connectionState(connected: Boolean) = engine.hop { engine.onState(link, gen, connected) }
    fun servicesDiscovered(ok: Boolean) = engine.hop { engine.onServices(link, gen, ok) }
    fun writeDone(ok: Boolean) = engine.hop { engine.onOpDone(link, gen, ok) }
    fun readDone(isBattery: Boolean, value: ByteArray?, ok: Boolean) {
        val v = if (ok && isBattery && value != null && value.isNotEmpty())
            (value[0].toInt() and 0xFF).coerceIn(0, 100) else null
        engine.hop { engine.onOpDone(link, gen, v) }
    }
    fun buttonPressed() = engine.hop { engine.onButton(link, gen) }
}

class ItagEngine(private val host: ItagHost) {
    companion object {
        const val OP_TIMEOUT_MS = 4000L
        const val WRITE_NO_RESPONSE_MS = 600L
        const val CONNECT_TIMEOUT_MS = 15000L
        const val RETRY_DELAY_MS = 600L
    }

    internal class Op(
        val run: (ItagGatt) -> Boolean,
        val done: (Any?) -> Unit,
        val timeoutMs: Long,
    ) {
        var finished = false
    }

    class Link internal constructor(val address: String) {
        internal var gatt: ItagGatt? = null
        internal var gen = 0
        internal var ready = false
        internal var retriesLeft = 1
        internal val pending = ArrayList<(Boolean) -> Unit>()
        internal val queue = ArrayDeque<Op>()
        internal var busy: Op? = null
    }

    private val links = HashMap<String, Link>()

    internal fun hop(r: () -> Unit) = host.post { try { r() } catch (_: Throwable) {} }

    fun isReady(address: String) = links[address]?.ready == true
    fun linkCount() = links.size

    // ---- connect ------------------------------------------------------------

    fun connect(address: String, reply: (Boolean) -> Unit) {
        if (!host.radioOn() || !host.canConnect() || !host.validAddress(address)) {
            safe { reply(false) }; return
        }
        val existing = links[address]
        if (existing != null) {
            if (existing.ready) { safe { reply(true) }; return }
            existing.pending.add(reply) // a connect is in flight: join it
            return
        }
        val link = Link(address)
        link.pending.add(reply)
        links[address] = link
        if (!open(link)) return
        host.postDelayed(CONNECT_TIMEOUT_MS) {
            if (links[address] === link && !link.ready) {
                finishConnect(link, false)
                close(address, user = true, silent = true)
            }
        }
    }

    private fun open(link: Link): Boolean {
        link.gen += 1
        val g = try { host.open(link.address, ItagGattEvents(this, link, link.gen)) } catch (_: Throwable) { null }
        link.gatt = g
        if (g == null) {
            if (links[link.address] === link) links.remove(link.address)
            finishConnect(link, false)
            return false
        }
        return true
    }

    private fun finishConnect(link: Link, ok: Boolean) {
        val rs = ArrayList(link.pending)
        link.pending.clear()
        for (r in rs) safe { r(ok) }
    }

    private fun current(link: Link, gen: Int) = links[link.address] === link && link.gen == gen

    internal fun onState(link: Link, gen: Int, connected: Boolean) {
        if (!current(link, gen)) return
        if (connected) {
            val ok = try { link.gatt?.discoverServices() == true } catch (_: Throwable) { false }
            if (!ok) failSession(link)
            return
        }
        failSession(link)
    }

    /** the GATT session dropped (or could not start discovery) */
    private fun failSession(link: Link) {
        val wasReady = link.ready
        if (!wasReady && link.pending.isNotEmpty() && link.retriesLeft > 0 && host.radioOn()) {
            // a fast first failure (GATT 133 on many phones): retry once, silently
            link.retriesLeft -= 1
            val old = link.gatt
            link.gatt = null
            link.gen += 1 // ignore anything the old session still says
            try { old?.close() } catch (_: Throwable) {}
            val genAtRetry = link.gen
            host.postDelayed(RETRY_DELAY_MS) {
                if (links[link.address] === link && link.gen == genAtRetry && !link.ready) {
                    open(link)
                }
            }
            return
        }
        finishConnect(link, false)
        close(link.address, user = false, silent = !wasReady)
    }

    internal fun onServices(link: Link, gen: Int, ok: Boolean) {
        if (!current(link, gen)) return
        if (!ok) {
            finishConnect(link, false)
            close(link.address, user = true, silent = true)
            return
        }
        link.ready = true
        enableButton(link)
        finishConnect(link, true)
        host.emit("connected", link.address, false, false)
    }

    internal fun onButton(link: Link, gen: Int) {
        if (!current(link, gen) || !link.ready) return
        host.emit("button", link.address, false, false)
    }

    // ---- close / radio ------------------------------------------------------

    fun disconnect(address: String) = close(address, user = true, silent = false)

    private fun close(address: String, user: Boolean, silent: Boolean, radioOff: Boolean = false) {
        val link = links.remove(address) ?: return
        val wasReady = link.ready
        link.ready = false
        link.gen += 1
        failAll(link)
        finishConnect(link, false) // never leave a connect unanswered
        try { link.gatt?.disconnect() } catch (_: Throwable) {}
        try { link.gatt?.close() } catch (_: Throwable) {}
        link.gatt = null
        if (!silent && (wasReady || user)) host.emit("disconnected", address, user, radioOff)
    }

    /** Bluetooth turned off / on (Android: ACTION_STATE_CHANGED). */
    fun onRadio(on: Boolean) {
        if (!on) {
            for (a in links.keys.toList()) {
                val l = links[a] ?: continue
                close(a, user = false, silent = !l.ready, radioOff = true)
            }
        }
        host.emit("radio", "", false, !on)
    }

    // ---- serialized GATT ops ------------------------------------------------

    fun ring(address: String, level: Int, reply: (Boolean) -> Unit) =
        writeAlert(address, ItagService.IMMEDIATE_ALERT, level, reply)

    fun linkLoss(address: String, level: Int, reply: (Boolean) -> Unit) =
        writeAlert(address, ItagService.LINK_LOSS, level, reply)

    private fun writeAlert(address: String, svc: ItagService, level: Int, reply: (Boolean) -> Unit) {
        val link = links[address]
        if (link == null || !link.ready) { safe { reply(false) }; return }
        val lv = level.coerceIn(0, 2)
        // a write without response may never call back on some phones: the
        // short timeout counts a started write as sent (null -> true)
        enqueue(link, Op({ g -> g.writeAlert(svc, lv) }, { v -> reply(v != false) }, WRITE_NO_RESPONSE_MS))
    }

    fun battery(address: String, reply: (Int?) -> Unit) {
        val link = links[address]
        if (link == null || !link.ready) { safe { reply(null) }; return }
        enqueue(link, Op({ g -> g.readBattery() }, { v -> reply(v as? Int) }, OP_TIMEOUT_MS))
    }

    private fun enableButton(link: Link) =
        enqueue(link, Op({ g -> g.enableButton() }, { }, OP_TIMEOUT_MS))

    private fun enqueue(link: Link, op: Op) {
        link.queue.addLast(op)
        pump(link)
    }

    private fun pump(link: Link) {
        if (link.busy != null) return
        val g = link.gatt ?: return failAll(link)
        val op = link.queue.removeFirstOrNull() ?: return
        link.busy = op
        val started = try { op.run(g) } catch (_: Throwable) { false }
        if (!started) { complete(link, op, false); return }
        host.postDelayed(op.timeoutMs) { complete(link, op, null) }
    }

    internal fun onOpDone(link: Link, gen: Int, value: Any?) {
        if (!current(link, gen)) return
        link.busy?.let { complete(link, it, value) }
    }

    private fun complete(link: Link, op: Op, value: Any?) {
        if (op.finished) return
        op.finished = true
        if (link.busy === op) link.busy = null
        safe { op.done(value) }
        pump(link)
    }

    private fun failAll(link: Link) {
        link.busy?.let { if (!it.finished) { it.finished = true; safe { it.done(false) } } }
        link.busy = null
        while (link.queue.isNotEmpty()) {
            val op = link.queue.removeFirst()
            op.finished = true
            safe { op.done(false) }
        }
    }

    private inline fun safe(f: () -> Unit) { try { f() } catch (_: Throwable) {} }
}
