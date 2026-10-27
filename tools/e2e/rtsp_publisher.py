"""Publish a synthetic CCTV scene as a real H.264 RTSP stream (e2e harness).

    python rtsp_publisher.py --url rtsp://pub:pubpw@127.0.0.1:18554/cam1 \
        --person "$E2E_CACHE/astronaut.png"

Scene, looping every --period seconds: an empty "room" (static background +
a timestamp) for the first third, then a PERSON walks in from the left and
crosses the frame. The person is a public-domain photo (NASA portrait of
astronaut Eileen Collins, shipped by scikit-image as `astronaut.png`; NASA
images are public domain) — never personal data. Without --person a plain
moving block is used (motion only; no person).

Needs PyAV (pip install av==13.1.0 into a scratch --target dir); the harness
pushes this to mediamtx, which serves it to the Shop Box like a real camera.
"""
import argparse
import time

import numpy as np


def background(w, h):
    img = np.zeros((h, w, 3), np.uint8)
    for y in range(h):                       # wall / floor gradient
        v = 150 + int(50 * y / h)
        img[y, :, :] = (v - 20, v - 10, v)
    img[int(h * 0.72):, :, :] = (70, 90, 110)  # floor
    img[int(h * 0.15):int(h * 0.55), int(w * 0.7):int(w * 0.9)] = (40, 60, 90)  # door
    return img


def load_person(path, h_target):
    import cv2
    p = cv2.imread(path, cv2.IMREAD_COLOR)
    if p is None:
        raise SystemExit("cannot read person image %s" % path)
    s = h_target / p.shape[0]
    return cv2.resize(p, (max(1, int(p.shape[1] * s)), h_target),
                      interpolation=cv2.INTER_AREA)


def frame_at(t, bg, person, period, w, h):
    import cv2
    img = bg.copy()
    phase = (t % period) / period
    if phase >= 1 / 3.0:
        k = (phase - 1 / 3.0) / (2 / 3.0)            # 0..1 across the frame
        if person is not None:
            ph, pw = person.shape[:2]
            x = int(-pw * 0.3 + k * (w - pw * 0.4))
            y = h - ph - int(h * 0.05)
            x0, x1 = max(0, x), min(w, x + pw)
            if x1 > x0:
                img[y:y + ph, x0:x1] = person[:, x0 - x:x1 - x]
        else:
            x = int(k * (w - 80))
            img[h // 3:h // 3 + 120, x:x + 80] = (20, 20, 200)
    cv2.putText(img, time.strftime("%H:%M:%S"), (10, 24),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--person", default="")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=360)
    ap.add_argument("--fps", type=int, default=10)
    ap.add_argument("--period", type=float, default=12.0)
    a = ap.parse_args()
    import av

    w, h = a.width, a.height
    bg = background(w, h)
    person = load_person(a.person, int(h * 0.8)) if a.person else None
    while True:
        try:
            out = av.open(a.url, mode="w", format="rtsp",
                          options={"rtsp_transport": "tcp"})
            st = out.add_stream("libx264", rate=a.fps)
            st.width, st.height, st.pix_fmt = w, h, "yuv420p"
            st.options = {"preset": "ultrafast", "tune": "zerolatency",
                          "g": str(a.fps)}
            t0 = time.monotonic()
            n = 0
            while True:
                t = time.monotonic() - t0
                img = frame_at(t, bg, person, a.period, w, h)
                vf = av.VideoFrame.from_ndarray(img, format="bgr24")
                vf.pts = n
                for pkt in st.encode(vf):
                    out.mux(pkt)
                n += 1
                nxt = t0 + n / a.fps
                d = nxt - time.monotonic()
                if d > 0:
                    time.sleep(d)
        except KeyboardInterrupt:
            return
        except Exception as e:                     # server restarting: retry
            print("publisher: %s — retrying" % type(e).__name__, flush=True)
            time.sleep(1.0)


if __name__ == "__main__":
    main()
