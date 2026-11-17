#!/usr/bin/env python3
"""flag-antitheft: physics-modelled SYNTHETIC snatch / no-snatch traces for
the false-alarm cases seen on live (17 Nov: 10 unverified "grab" alerts, all
evenings, phone not charging, not face-down). Deterministic (fixed seeds).
These are NOT real phone recordings — the harness prints them as
`synthetic`; recorded traces (source=recorded...) are measured separately.

Run:  python3 app/test/fixtures/gen_flag_antitheft_traces.py
Writes app/test/fixtures/sensor_traces/fa_*.csv (50 Hz raw accelerometer).
"""
import math
import os
import random

DT = 20  # ms, ~50 Hz (SENSOR_DELAY_GAME)
G = 9.81
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sensor_traces")


class Trace:
    def __init__(self, seed, tilt=(0.0, 0.0, 1.0)):
        self.r = random.Random(seed)
        self.t = 0
        self.rows = []
        self.tilt = tilt

    def _g(self):
        x, y, z = self.tilt
        n = math.sqrt(x * x + y * y + z * z)
        return (G * x / n, G * y / n, G * z / n)

    def emit(self, lx, ly, lz, noise=0.05):
        gx, gy, gz = self._g()
        r = self.r
        self.rows.append((self.t, gx + lx + r.gauss(0, noise),
                          gy + ly + r.gauss(0, noise), gz + lz + r.gauss(0, noise)))
        self.t += DT

    def still(self, ms):
        for _ in range(ms // DT):
            self.emit(0, 0, 0)

    def spike(self, peak, n=3):
        """A sudden yank / impact: [n] samples around [peak] m/s^2."""
        for i in range(n):
            a = peak * (1.0 - 0.15 * i)
            self.emit(a * 0.6, a * 0.5, a * 0.6, noise=0.5)

    def gait(self, ms, hz, amp, jitter=0.05, floor=0.0, noise=0.4):
        """Steps: a half-sine impulse per step on a [floor] base, cadence
        [hz] with [jitter] relative variation of the interval."""
        end = self.t + ms
        nxt = self.t
        width = 0.0
        while self.t < end:
            if self.t >= nxt:
                width = 1000.0 / hz * 0.55
                start = self.t
                nxt = self.t + int(1000.0 / hz * (1 + self.r.uniform(-jitter, jitter)))
            ph = (self.t - start) / width if width else 2
            a = amp * math.sin(math.pi * ph) if 0 <= ph <= 1 else 0.0
            a += floor
            self.emit(a * 0.3, a * 0.5, a * 0.8, noise=noise)

    def shake(self, ms, rms, jolts_per_s=0.0, jolt=0.0):
        """Irregular vibration (a rickshaw / CNG on a broken road): random
        band noise of [rms] plus random hard jolts."""
        end = self.t + ms
        v = [0.0, 0.0, 0.0]
        while self.t < end:
            v = [0.6 * v[i] + self.r.gauss(0, rms) for i in range(3)]
            j = 0.0
            if jolts_per_s and self.r.random() < jolts_per_s * DT / 1000.0:
                j = jolt * self.r.uniform(0.6, 1.0)
            self.emit(v[0] + j * 0.5, v[1] + j * 0.5, v[2] + j * 0.7, noise=0.2)

    def run(self, ms, hz, amp, jitter=0.05, noise=0.6):
        """Running with the phone in a fist: the body/arm oscillates at the
        stride rate (zero-mean, so a gravity low-pass does not absorb it);
        the cycle length varies by [jitter]."""
        end = self.t + ms
        ph = 0.0
        f = hz / 2.0  # magnitude repeats twice per stride cycle
        while self.t < end:
            ph += 2 * math.pi * f * DT / 1000.0
            if ph > 2 * math.pi:
                ph -= 2 * math.pi
                f = hz / 2.0 * (1 + self.r.uniform(-jitter, jitter))
            a = amp * math.sin(ph)
            self.emit(a * 0.3, a * 0.6, a * 0.75, noise=noise)

    def fall(self, ms):
        """Free fall: the accelerometer reads ~0 (linear ~ -g)."""
        for _ in range(ms // DT):
            gx, gy, gz = self._g()
            self.emit(-gx, -gy, -gz, noise=0.3)

    def write(self, name, meta, detector="snatch"):
        path = os.path.join(OUT, name + ".csv")
        with open(path, "w") as f:
            f.write("# source=synthetic (physics-modelled, NOT a real phone recording)\n")
            f.write("# detector=%s\n" % detector)
            for k, v in meta.items():
                f.write("# %s=%s\n" % (k, v))
            f.write("t_ms,x,y,z\n")
            for t, x, y, z in self.rows:
                f.write("%d,%.3f,%.3f,%.3f\n" % (t, x, y, z))


IN_HAND = (0.0, 0.7, 0.7)
FLAT = (0.0, 0.0, 1.0)


def main():
    # 1. phone slips out of the hand, hits the floor, lies there face-up
    t = Trace(101, IN_HAND)
    t.gait(6000, 1.8, 2.5)
    t.fall(350)
    t.tilt = FLAT
    t.spike(55.0, 3)
    t.shake(400, 3.0)
    t.still(8000)
    t.write("fa_nosnatch_dropped_on_floor_left", {
        "label": "nosnatch", "screen_on": "1", "hour": "19",
        "note": "slips from the hand while walking, hits the floor, lies still"})

    # 2. picked up hard from the table, dropped in a bag, owner walks off
    t = Trace(102, FLAT)
    t.still(6000)
    t.spike(34.0, 3)
    t.tilt = (0.3, 0.9, 0.2)
    t.shake(600, 4.0)
    t.gait(9000, 1.9, 2.0, jitter=0.08, noise=0.6)
    t.write("fa_nosnatch_table_to_bag_walk", {
        "label": "nosnatch", "screen_on": "0", "hour": "20",
        "note": "grabbed off the table by the owner, put in a bag, walking"})

    # 3. fast walk, phone in hand and in use, a hard bump against a bag
    t = Trace(103, IN_HAND)
    t.gait(5000, 2.1, 4.0)
    t.spike(30.0, 3)
    t.gait(9000, 2.2, 5.0, jitter=0.12)
    t.write("fa_nosnatch_fast_walk_in_use_bump", {
        "label": "nosnatch", "screen_on": "1", "in_use": "1",
        "hour": "18", "note": "fast walk, phone unlocked in hand, a hard bump"})

    # 4. rickshaw on a broken road, phone in use, hard pothole jolts
    t = Trace(104, IN_HAND)
    t.shake(5000, 3.5, 1.0, 30.0)
    t.spike(32.0, 3)
    t.shake(12000, 5.5, 1.5, 32.0)
    t.write("fa_nosnatch_rickshaw_potholes_in_use", {
        "label": "nosnatch", "screen_on": "1", "in_use": "1",
        "hour": "21", "note": "rickshaw ride, phone in use, pothole jolts"})

    # 5. tossed onto the sofa, bounces, lies there
    t = Trace(105, IN_HAND)
    t.still(4000)
    t.spike(28.0, 3)
    t.fall(200)
    t.tilt = FLAT
    t.spike(26.0, 2)
    t.shake(800, 2.5)
    t.still(8000)
    t.write("fa_nosnatch_tossed_on_sofa", {
        "label": "nosnatch", "screen_on": "0", "hour": "22",
        "note": "tossed onto a sofa, bounces, lies still"})

    # 6. REAL: snatched from the hand in a rickshaw, thief jumps off and runs
    t = Trace(106, IN_HAND)
    t.shake(5000, 2.0)
    t.spike(38.0, 3)
    t.tilt = (0.4, 0.4, 0.8)
    t.run(9000, 2.8, 14.0)
    t.write("fa_snatch_from_hand_rickshaw_thief_runs", {
        "label": "snatch", "screen_on": "1", "in_use": "1",
        "hour": "20", "note": "phone in use on a rickshaw, grabbed, thief runs"})

    # 7. REAL: grabbed off a shop counter (screen off, lying still), run
    t = Trace(107, FLAT)
    t.still(6000)
    t.spike(40.0, 3)
    t.tilt = (0.2, 0.6, 0.7)
    t.run(9000, 3.0, 15.0)
    t.write("fa_snatch_shop_counter_run", {
        "label": "snatch", "screen_on": "0", "hour": "17",
        "note": "lying on a shop counter, grabbed, thief runs"})

    # 8. antitheft-e2e: BORDERLINE — phone in use, a grab just under the
    # normal grab threshold, then a real run. The owner's sensitivity decides:
    # low = never (unlocked hand), normal = no (grab too weak), high = alert.
    # Own detector tag: kept out of the precision/recall harness (its label
    # depends on the setting); test/antitheft_e2e_borderline_test.dart.
    t = Trace(108, IN_HAND)
    t.shake(5000, 2.0)
    t.spike(29.0, 3)  # 2nd sample ~24.5: >= 22.5 (high), < 25 (normal)
    t.tilt = (0.4, 0.4, 0.8)
    t.run(9000, 2.8, 14.0)
    t.write("fa_borderline_in_hand_weak_grab_run", {
        "label": "high_only", "screen_on": "1", "in_use": "1", "hour": "19",
        "note": "in use, weak grab (between the high and normal thresholds), run"},
        detector="snatch_borderline")


if __name__ == "__main__":
    main()
