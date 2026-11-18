// itag-proof (18 Nov): JVM unit tests of the phone's own iTag link engine
// (app/android_overlay/.../itag/ItagEngine.kt) with a FAKE GATT and a virtual
// clock — no phone, no Bluetooth. Run by .github/workflows/itag-proof.yml:
//   kotlinc ItagEngine.kt ItagEngineTest.kt -cp junit.jar -> JUnitCore
// Story covered: connect -> ring (Immediate Alert level 2) -> battery ->
// button notification -> link loss (disconnected, not by the user) ->
// back in range (connect again) + the reliability cases (GATT 133 retry,
// timeouts, Bluetooth off mid-session, stale callbacks, two callers).
package com.assisto.assisto.itag

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** A virtual main thread: post = now, postDelayed = later; advance() runs them. */
class FakeHost : ItagHost {
    var now = 0L
    private var seq = 0
    private val tasks = ArrayList<Triple<Long, Int, () -> Unit>>()
    var radio = true
    var permitted = true
    val events = ArrayList<String>()
    val gatts = ArrayList<FakeGatt>()
    var openFails = false
    var openThrows = false

    override fun radioOn() = radio
    override fun canConnect() = permitted
    override fun validAddress(address: String) = address.matches(Regex("([0-9A-F]{2}:){5}[0-9A-F]{2}"))
    override fun open(address: String, events: ItagGattEvents): ItagGatt? {
        if (openThrows) throw IllegalStateException("vendor quirk")
        if (openFails) return null
        return FakeGatt(events).also { gatts.add(it) }
    }
    override fun post(r: () -> Unit) { tasks.add(Triple(now, seq++, r)) }
    override fun postDelayed(ms: Long, r: () -> Unit) { tasks.add(Triple(now + ms, seq++, r)) }
    override fun emit(type: String, address: String, user: Boolean, radioOff: Boolean) {
        events.add(buildString {
            append(type); if (address.isNotEmpty()) append(" ").append(address)
            if (user) append(" user"); if (radioOff) append(" radioOff")
        })
    }

    /** run everything due up to now + ms (in time, then post order) */
    fun advance(ms: Long = 0) {
        val end = now + ms
        while (true) {
            val next = tasks.filter { it.first <= end }.minWithOrNull(compareBy({ it.first }, { it.second })) ?: break
            tasks.remove(next)
            now = maxOf(now, next.first)
            next.third()
        }
        now = end
    }
}

/** A fake iTag GATT session: records what the phone wrote and read. */
class FakeGatt(val ev: ItagGattEvents) : ItagGatt {
    val writes = ArrayList<Pair<ItagService, Int>>()
    var reads = 0
    var buttonEnabled = false
    var discovers = 0
    var closed = false
    var disconnected = false
    var hasBattery = true
    var hasAlert = true
    override fun discoverServices(): Boolean { discovers++; return true }
    override fun writeAlert(service: ItagService, level: Int): Boolean {
        if (!hasAlert) return false
        writes.add(service to level); return true
    }
    override fun readBattery(): Boolean { if (!hasBattery) return false; reads++; return true }
    override fun enableButton(): Boolean { buttonEnabled = true; return true }
    override fun disconnect() { disconnected = true }
    override fun close() { closed = true }
}

class ItagEngineTest {
    private val tag = "AA:BB:CC:DD:EE:01"
    private lateinit var host: FakeHost
    private lateinit var engine: ItagEngine

    @Before fun setUp() {
        host = FakeHost()
        engine = ItagEngine(host)
    }

    /** connect + the tag answers: link up, services found, CCCD written */
    private fun connected(): FakeGatt {
        var ok: Boolean? = null
        engine.connect(tag) { ok = it }
        val g = host.gatts.last()
        g.ev.connectionState(true); host.advance()
        assertEquals(1, g.discovers)
        g.ev.servicesDiscovered(true); host.advance()
        assertEquals(true, ok)
        assertTrue("button notifications enabled", g.buttonEnabled)
        g.ev.writeDone(true); host.advance() // CCCD write acknowledged
        return g
    }

    @Test fun connectFindsServicesThenSaysConnected() {
        connected()
        assertTrue(engine.isReady(tag))
        assertEquals(listOf("connected $tag"), host.events)
    }

    @Test fun ringWritesImmediateAlertLevel2AndStopWrites0() {
        val g = connected()
        var r1: Boolean? = null
        engine.ring(tag, 2) { r1 = it }
        g.ev.writeDone(true); host.advance()
        assertEquals(true, r1)
        var r2: Boolean? = null
        engine.ring(tag, 0) { r2 = it }
        g.ev.writeDone(true); host.advance()
        assertEquals(true, r2)
        engine.ring(tag, 9) { } // never more than "high"
        host.advance(700)
        assertEquals(listOf(ItagService.IMMEDIATE_ALERT to 2, ItagService.IMMEDIATE_ALERT to 0,
            ItagService.IMMEDIATE_ALERT to 2), g.writes)
    }

    @Test fun linkLossLevelGoesToTheLinkLossService() {
        val g = connected()
        engine.linkLoss(tag, 2) { }
        host.advance(700)
        assertEquals(listOf(ItagService.LINK_LOSS to 2), g.writes)
    }

    @Test fun writeWithoutResponseThatNeverCallsBackCountsAsSentAfter600ms() {
        val g = connected()
        var r: Boolean? = null
        engine.ring(tag, 2) { r = it }
        host.advance(500); assertNull(r)
        host.advance(150); assertEquals(true, r)
        // the queue moves on: the next op runs
        engine.battery(tag) { }
        assertEquals(1, g.reads)
    }

    @Test fun ringFailsWhenTheTagHasNoAlertService() {
        val g = connected(); g.hasAlert = false
        var r: Boolean? = null
        engine.ring(tag, 2) { r = it }; host.advance()
        assertEquals(false, r)
    }

    @Test fun batteryReadsTheLevel() {
        val g = connected()
        var b: Int? = -1
        engine.battery(tag) { b = it }
        assertEquals(1, g.reads)
        g.ev.readDone(true, byteArrayOf(87), true); host.advance()
        assertEquals(87, b)
        // a raw byte above 100 is clamped; another characteristic is ignored
        engine.battery(tag) { b = it }
        g.ev.readDone(true, byteArrayOf(0xC8.toByte()), true); host.advance()
        assertEquals(100, b)
        engine.battery(tag) { b = it }
        g.ev.readDone(false, byteArrayOf(5), true); host.advance()
        assertNull(b)
    }

    @Test fun batteryMissingOrSilentGivesNull() {
        val g = connected()
        var b: Int? = -1
        g.hasBattery = false
        engine.battery(tag) { b = it }; host.advance()
        assertNull(b)
        g.hasBattery = true
        b = -1
        engine.battery(tag) { b = it }
        host.advance(3900); assertEquals(-1, b)
        host.advance(200); assertNull(b) // 4 s timeout
    }

    @Test fun opsAreSerializedOneAtATime() {
        val g = connected()
        val order = ArrayList<String>()
        engine.battery(tag) { order.add("battery $it") }
        engine.ring(tag, 2) { order.add("ring $it") }
        assertEquals("the ring waits for the read", 0, g.writes.size)
        g.ev.readDone(true, byteArrayOf(50), true); host.advance()
        assertEquals(1, g.writes.size)
        g.ev.writeDone(true); host.advance()
        assertEquals(listOf("battery 50", "ring true"), order)
    }

    @Test fun buttonNotificationIsSentToTheApp() {
        val g = connected()
        g.ev.buttonPressed(); host.advance()
        assertEquals("button $tag", host.events.last())
    }

    @Test fun linkLossSaysDisconnectedNotByTheUserAndFailsQueuedOps() {
        val g = connected()
        var r: Boolean? = null
        engine.battery(tag) { }
        engine.ring(tag, 2) { r = it } // queued behind the read
        g.ev.connectionState(false); host.advance()
        assertEquals("disconnected $tag", host.events.last())
        assertEquals(false, r)
        assertFalse(engine.isReady(tag))
        assertTrue(g.closed)
        var r2: Boolean? = null
        engine.ring(tag, 2) { r2 = it }
        assertEquals(false, r2) // not linked: answered at once
    }

    @Test fun backInRangeConnectsAgainAndSaysConnected() {
        val g1 = connected()
        g1.ev.connectionState(false); host.advance()
        val g2 = connected() // the app's auto-reconnect calls connect again
        assertTrue(g2 !== g1)
        assertEquals(listOf("connected $tag", "disconnected $tag", "connected $tag"), host.events)
        // a late callback from the dead session changes nothing
        g1.ev.buttonPressed(); g1.ev.connectionState(false); host.advance()
        assertEquals(3, host.events.size)
        assertTrue(engine.isReady(tag))
    }

    @Test fun userDisconnectIsMarkedUser() {
        val g = connected()
        engine.disconnect(tag); host.advance()
        assertEquals("disconnected $tag user", host.events.last())
        assertTrue(g.disconnected && g.closed)
    }

    @Test fun fastFirstFailureRetriesOnceSilently() {
        var ok: Boolean? = null
        engine.connect(tag) { ok = it }
        host.gatts[0].ev.connectionState(false); host.advance() // GATT 133
        assertNull(ok)
        assertTrue(host.gatts[0].closed)
        assertEquals(1, host.gatts.size)
        host.advance(ItagEngine.RETRY_DELAY_MS)
        assertEquals(2, host.gatts.size)
        val g = host.gatts[1]
        g.ev.connectionState(true); host.advance()
        g.ev.servicesDiscovered(true); host.advance()
        assertEquals(true, ok)
        assertEquals(listOf("connected $tag"), host.events) // no false "disconnected"
    }

    @Test fun secondFailureGivesUpWithoutADisconnectEvent() {
        var ok: Boolean? = null
        engine.connect(tag) { ok = it }
        host.gatts[0].ev.connectionState(false); host.advance(ItagEngine.RETRY_DELAY_MS)
        host.gatts[1].ev.connectionState(false); host.advance()
        assertEquals(false, ok)
        assertEquals(0, engine.linkCount())
        assertTrue(host.events.isEmpty())
    }

    @Test fun connectTimesOutAfter15sAndAnswersFalse() {
        var ok: Boolean? = null
        engine.connect(tag) { ok = it }
        host.advance(14_000); assertNull(ok)
        host.advance(1_100)
        assertEquals(false, ok)
        assertTrue(host.gatts[0].closed)
        assertEquals(0, engine.linkCount())
    }

    @Test fun staleConnectTimerNeverClosesANewerLink() {
        // regression (old ItagChannel): the first attempt's 15 s timer closed
        // the NEXT link by address, and a replaced attempt was never answered
        var first: Boolean? = null
        engine.connect(tag) { first = it }
        engine.disconnect(tag) // the user gives up (screen closed)
        assertEquals(false, first)
        host.advance(5_000)
        val g = connected() // a fresh pair attempt at t = 5 s
        host.advance(12_000) // the first attempt's timer fires at t = 15 s
        assertTrue(engine.isReady(tag))
        assertFalse(g.closed)
    }

    @Test fun twoCallersOfOneConnectShareOneSession() {
        val got = ArrayList<Boolean>()
        engine.connect(tag) { got.add(it) }
        engine.connect(tag) { got.add(it) }
        assertEquals(1, host.gatts.size)
        host.gatts[0].ev.connectionState(true); host.advance()
        host.gatts[0].ev.servicesDiscovered(true); host.advance()
        assertEquals(listOf(true, true), got)
        engine.connect(tag) { got.add(it) } // already linked
        assertEquals(listOf(true, true, true), got)
    }

    @Test fun bluetoothTurnedOffMidSessionClosesWithRadioOff() {
        val g = connected()
        host.radio = false
        engine.onRadio(false); host.advance()
        assertEquals(listOf("connected $tag", "disconnected $tag radioOff", "radio radioOff"), host.events)
        assertTrue(g.closed)
        var ok: Boolean? = null
        engine.connect(tag) { ok = it } // while off: answered at once
        assertEquals(false, ok)
        host.radio = true
        engine.onRadio(true)
        assertEquals("radio", host.events.last())
        connected()
    }

    @Test fun bluetoothOffDuringAConnectAnswersFalseSilently() {
        var ok: Boolean? = null
        engine.connect(tag) { ok = it }
        host.radio = false
        engine.onRadio(false)
        assertEquals(false, ok)
        assertEquals(listOf("radio radioOff"), host.events)
    }

    @Test fun noPermissionOrBadAddressOrVendorThrowNeverCrash() {
        val got = ArrayList<Boolean>()
        host.permitted = false
        engine.connect(tag) { got.add(it) }
        host.permitted = true
        engine.connect("not-an-address") { got.add(it) }
        host.openThrows = true
        engine.connect(tag) { got.add(it) }
        host.openThrows = false; host.openFails = true
        engine.connect(tag) { got.add(it) }
        assertEquals(listOf(false, false, false, false), got)
        assertEquals(0, engine.linkCount())
    }

    @Test fun servicesNotFoundFailsTheConnect() {
        var ok: Boolean? = null
        engine.connect(tag) { ok = it }
        host.gatts[0].ev.connectionState(true); host.advance()
        host.gatts[0].ev.servicesDiscovered(false); host.advance()
        assertEquals(false, ok)
        assertTrue(host.events.isEmpty())
    }

    @Test fun aThrowingReplyNeverBreaksTheEngine() {
        val g = connected()
        engine.battery(tag) { throw RuntimeException("Dart side gone") }
        g.ev.readDone(true, byteArrayOf(10), true); host.advance()
        var r: Boolean? = null
        engine.ring(tag, 2) { r = it }
        g.ev.writeDone(true); host.advance()
        assertEquals(true, r)
    }
}
