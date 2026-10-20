"""Small local configuration UI (tkinter, stdlib only — no web server, no
listening port).

Everything slow (camera connects, server checks) runs on a worker thread; the
result is handed back to Tk via a queue polled with `after()`, because Tk
widgets must only be touched from the main thread.
"""
from __future__ import annotations

import base64
import logging
import queue
import threading
import time
import tkinter as tk
from tkinter import ttk

from . import payload
from .camera import grab_one_frame
from .config import CameraConfig, join_rtsp_credentials, normalize_base_url, \
    split_rtsp_credentials
from .hours import Hours, parse_hhmm
from .secure_store import SITE_TOKEN, SecretStore, cam_key
from .strings import Tr

log = logging.getLogger(__name__)

PAD = {"padx": 6, "pady": 4}


def _frame_to_photo(frame_bgr, max_w: int = 800):
    """BGR ndarray -> (tk.PhotoImage, scale). Uses PNG via Tk's built-in decoder
    (Tk 8.6), so no Pillow dependency."""
    import cv2

    h, w = frame_bgr.shape[:2]
    scale = min(1.0, max_w / float(w))
    if scale < 1.0:
        frame_bgr = cv2.resize(frame_bgr, (int(w * scale), int(h * scale)),
                               interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".png", frame_bgr)
    if not ok:
        raise ValueError("png encode failed")
    return tk.PhotoImage(data=base64.b64encode(buf.tobytes())), frame_bgr.shape[:2]


class App:
    def __init__(self, root: tk.Tk, cfg, cstore):
        self.root = root
        self.cfg = cfg
        self.cstore = cstore
        self.store = SecretStore()
        from .engine import EventLog
        self.events = EventLog()          # shared with each Engine session
        self.engine = None
        self.tr = Tr(cfg.language)
        self.results: "queue.Queue" = queue.Queue()
        self._pending_remove = None
        self.build()
        self.root.after(300, self._poll)
        self.root.after(1000, self._refresh)
        if cfg.auto_start and self.store.get(SITE_TOKEN) and cfg.cameras:
            self.root.after(1500, self.toggle_run)

    # ------------------------------------------------------------- threading
    def _bg(self, fn, done):
        """Run fn() on a thread, call done(result) on the Tk thread."""
        def work():
            try:
                res = fn()
            except Exception as exc:          # surfaced as a failed result
                log.warning("background task failed: %s", type(exc).__name__)
                res = exc
            self.results.put((done, res))
        threading.Thread(target=work, daemon=True).start()

    def _poll(self):
        try:
            while True:
                done, res = self.results.get_nowait()
                done(res)
        except queue.Empty:
            pass
        self.root.after(200, self._poll)

    # ----------------------------------------------------------------- build
    def build(self):
        t = self.tr
        for w in self.root.winfo_children():
            w.destroy()
        self.root.title(t("app_title"))
        outer = ttk.Frame(self.root, padding=10)
        outer.pack(fill="both", expand=True)

        top = ttk.Frame(outer)
        top.pack(fill="x")
        ttk.Label(top, text=t("privacy_note"), wraplength=560).pack(side="left")
        ttk.Button(top, text=t("switch_lang"), command=self.switch_lang).pack(side="right")

        # --- pairing
        pf = ttk.LabelFrame(outer, text=t("sec_pair"))
        pf.pack(fill="x", **PAD)
        self.pair_status = ttk.Label(pf, wraplength=640)
        self.pair_status.grid(row=0, column=0, columnspan=3, sticky="w", **PAD)
        ttk.Label(pf, text=t("token_label")).grid(row=1, column=0, sticky="w", **PAD)
        self.token_var = tk.StringVar()
        ttk.Entry(pf, textvariable=self.token_var, show="•", width=44).grid(
            row=1, column=1, sticky="we", **PAD)
        ttk.Button(pf, text=t("pair_btn"), command=self.pair).grid(row=1, column=2, **PAD)
        ttk.Label(pf, text=t("server_label")).grid(row=2, column=0, sticky="w", **PAD)
        self.server_var = tk.StringVar(value=self.cfg.base_url)
        ttk.Entry(pf, textvariable=self.server_var, width=44).grid(
            row=2, column=1, sticky="we", **PAD)
        ttk.Button(pf, text=t("unpair_btn"), command=self.unpair).grid(row=2, column=2, **PAD)
        pf.columnconfigure(1, weight=1)

        # --- hours
        hf = ttk.LabelFrame(outer, text=t("sec_hours"))
        hf.pack(fill="x", **PAD)
        h = self.cfg.hours
        self.open_var = tk.StringVar(value=h["open"])
        self.close_var = tk.StringVar(value=h["close"])
        self.tz_var = tk.StringVar(value=h["timezone"])
        ttk.Label(hf, text=t("open_label")).grid(row=0, column=0, **PAD)
        ttk.Entry(hf, textvariable=self.open_var, width=7).grid(row=0, column=1, **PAD)
        ttk.Label(hf, text=t("close_label")).grid(row=0, column=2, **PAD)
        ttk.Entry(hf, textvariable=self.close_var, width=7).grid(row=0, column=3, **PAD)
        ttk.Label(hf, text=t("tz_label")).grid(row=0, column=4, **PAD)
        ttk.Entry(hf, textvariable=self.tz_var, width=16).grid(row=0, column=5, **PAD)
        ttk.Label(hf, text=t("closed_days_label")).grid(row=1, column=0, columnspan=2,
                                                        sticky="w", **PAD)
        days = ttk.Frame(hf)
        days.grid(row=1, column=2, columnspan=4, sticky="w")
        self.day_vars = []
        for i, name in enumerate(t("days")):
            v = tk.BooleanVar(value=i in h.get("closed_days", []))
            self.day_vars.append(v)
            ttk.Checkbutton(days, text=name, variable=v).pack(side="left")
        self.auto_var = tk.BooleanVar(value=self.cfg.auto_start)
        ttk.Checkbutton(hf, text=t("auto_start_label"), variable=self.auto_var).grid(
            row=2, column=0, columnspan=4, sticky="w", **PAD)
        ttk.Button(hf, text=t("save_btn"), command=self.save_hours).grid(row=2, column=5, **PAD)
        self.hours_msg = ttk.Label(hf)
        self.hours_msg.grid(row=3, column=0, columnspan=6, sticky="w", **PAD)

        # --- cameras
        cf = ttk.LabelFrame(outer, text=t("sec_cams"))
        cf.pack(fill="both", expand=True, **PAD)
        self.cam_tree = ttk.Treeview(cf, columns=("name", "status", "zone"),
                                     show="headings", height=5, selectmode="browse")
        for col, key, wd in (("name", "col_name", 220), ("status", "col_status", 140),
                             ("zone", "col_zone", 120)):
            self.cam_tree.heading(col, text=t(key))
            self.cam_tree.column(col, width=wd)
        self.cam_tree.pack(fill="both", expand=True, **PAD)
        bf = ttk.Frame(cf)
        bf.pack(fill="x")
        for key, cmd in (("add_btn", self.add_camera), ("edit_btn", self.edit_camera),
                         ("test_btn", self.test_camera), ("zone_btn", self.draw_zone),
                         ("remove_btn", self.remove_camera)):
            ttk.Button(bf, text=t(key), command=cmd).pack(side="left", **PAD)
        self.cam_msg = ttk.Label(cf, wraplength=640)
        self.cam_msg.pack(fill="x", **PAD)

        # --- run
        rf = ttk.LabelFrame(outer, text=t("sec_run"))
        rf.pack(fill="x", **PAD)
        self.run_btn = ttk.Button(rf, command=self.toggle_run)
        self.run_btn.pack(side="left", **PAD)
        self.run_status = ttk.Label(rf, wraplength=520, justify="left")
        self.run_status.pack(side="left", fill="x", **PAD)

        # --- events
        ef = ttk.LabelFrame(outer, text=t("sec_events"))
        ef.pack(fill="both", expand=True, **PAD)
        self.ev_tree = ttk.Treeview(ef, columns=("time", "camera", "what", "result"),
                                    show="headings", height=7)
        for col, key, wd in (("time", "col_time", 140), ("camera", "col_camera", 120),
                             ("what", "col_what", 300), ("result", "col_result", 220)):
            self.ev_tree.heading(col, text=t(key))
            self.ev_tree.column(col, width=wd)
        self.ev_tree.pack(fill="both", expand=True, **PAD)

        self._refresh_cams()
        self._refresh_pair()
        self._refresh_run()

    def switch_lang(self):
        self.cfg.language = "en" if self.cfg.language == "bn" else "bn"
        self.tr = Tr(self.cfg.language)
        self.cstore.save(self.cfg)
        self.build()

    # --------------------------------------------------------------- pairing
    def _refresh_pair(self):
        paired = bool(self.store.get(SITE_TOKEN))
        self.pair_status.config(text=self.tr("paired_yes" if paired else "paired_no"))

    def pair(self):
        tok = self.token_var.get().strip()
        if not tok:
            return
        self.cfg.base_url = normalize_base_url(self.server_var.get())
        self.cstore.save(self.cfg)
        self.pair_status.config(text=self.tr("pair_checking"))
        from .cli import pair_token

        def done(res):
            self.token_var.set("")          # never keep the token on screen
            key = {"ok": "pair_ok", "bad": "pair_bad", "offline": "pair_offline"}.get(
                res if isinstance(res, str) else "offline", "pair_offline")
            self.pair_status.config(text=self.tr(key))
        self._bg(lambda: pair_token(self.cfg, self.store, tok), done)

    def unpair(self):
        if self.engine and self.engine.running:
            self.toggle_run()
        self.store.set(SITE_TOKEN, None)
        self._refresh_pair()

    # ----------------------------------------------------------------- hours
    def save_hours(self):
        try:
            parse_hhmm(self.open_var.get())
            parse_hhmm(self.close_var.get())
        except ValueError:
            self.hours_msg.config(text=self.tr("bad_time"))
            return
        self.cfg.hours = Hours(
            open=self.open_var.get().strip(), close=self.close_var.get().strip(),
            timezone=self.tz_var.get().strip() or "Asia/Dhaka",
            closed_days=[i for i, v in enumerate(self.day_vars) if v.get()]).to_dict()
        self.cfg.auto_start = bool(self.auto_var.get())
        self.cstore.save(self.cfg)
        self.hours_msg.config(text=self.tr("saved"))

    # --------------------------------------------------------------- cameras
    def _selected(self):
        sel = self.cam_tree.selection()
        if not sel:
            self.cam_msg.config(text=self.tr("select_cam"))
            return None
        return self.cfg.camera(sel[0])

    def _refresh_cams(self):
        st = self.engine.status()["cameras"] if (self.engine and self.engine.running) else {}
        sel = self.cam_tree.selection()
        self.cam_tree.delete(*self.cam_tree.get_children())
        for c in self.cfg.cameras:
            s = st.get(c.id)
            status = self.tr("cam_%s" % s) if s else self.tr("cam_idle")
            self.cam_tree.insert("", "end", iid=c.id, values=(
                c.name, status, self.tr("zone_set" if c.zone else "zone_unset")))
        for i in sel:
            if self.cam_tree.exists(i):
                self.cam_tree.selection_set(i)

    def add_camera(self):
        CameraDialog(self, None)

    def edit_camera(self):
        cam = self._selected()
        if cam:
            CameraDialog(self, cam)

    def remove_camera(self):
        cam = self._selected()
        if not cam:
            return
        if self._pending_remove != cam.id:
            self._pending_remove = cam.id      # two-press confirm (no popups)
            self.cam_msg.config(text=self.tr("confirm_remove"))
            return
        self._pending_remove = None
        self.cfg.cameras = [c for c in self.cfg.cameras if c.id != cam.id]
        self.store.delete_prefix(cam_key(cam.id, ""))
        self.cstore.save(self.cfg)
        self.cam_msg.config(text=self.tr("saved"))
        self._refresh_cams()

    def camera_url(self, cam) -> str:
        return join_rtsp_credentials(cam.rtsp_url, self.store.get(cam_key(cam.id, "user")),
                                     self.store.get(cam_key(cam.id, "pass")))

    def test_camera(self):
        cam = self._selected()
        if not cam:
            return
        self.cam_msg.config(text=self.tr("testing"))
        url = self.camera_url(cam)

        def done(res):
            if isinstance(res, tuple) and res[0]:
                self.cam_msg.config(text=self.tr("test_ok", info=res[2]))
            else:
                self.cam_msg.config(text=self.tr("test_fail"))
        self._bg(lambda: grab_one_frame(url), done)

    def draw_zone(self):
        cam = self._selected()
        if not cam:
            return
        self.cam_msg.config(text=self.tr("testing"))
        url = self.camera_url(cam)

        def done(res):
            if isinstance(res, tuple) and res[0]:
                self.cam_msg.config(text="")
                ZoneEditor(self, cam, res[1])
            else:
                self.cam_msg.config(text=self.tr("test_fail"))
        self._bg(lambda: grab_one_frame(url), done)

    # ------------------------------------------------------------- run/state
    def toggle_run(self):
        from .engine import Engine

        if self.engine and self.engine.running:
            self.engine.stop()
            self.engine = None
        else:
            if not self.store.get(SITE_TOKEN):
                self.run_status.config(text=self.tr("need_pair"))
                return
            if not self.cfg.cameras:
                self.run_status.config(text=self.tr("need_cam"))
                return
            self.engine = Engine(self.cfg, self.store, events=self.events)
            try:
                self.engine.start()
            except RuntimeError:
                self.engine = None
                self.run_status.config(text=self.tr("need_pair"))
                return
        self._refresh_run()

    def _refresh_run(self):
        t = self.tr
        running = bool(self.engine and self.engine.running)
        self.run_btn.config(text=t("stop_btn" if running else "start_btn"))
        if not running:
            self.run_status.config(text=t("stopped"))
            return
        st = self.engine.status()
        lines = [t("running"),
                 t("detector_full" if st["detector"] != "motion_only" else "detector_motion"),
                 t("queue_line", n=st["queued"])]
        if st["unauthorized"]:
            lines.append(t("net_unauth"))
        elif st["online"] is None:
            lines.append(t("net_unknown"))
        else:
            lines.append(t("net_online" if st["online"] else "net_offline"))
        self.run_status.config(text="\n".join(lines))

    def _refresh_events(self):
        rows = self.events.recent(30)
        self.ev_tree.delete(*self.ev_tree.get_children())
        for r in rows:
            et = r.get("type") or ""
            what = self.tr("ev_%s" % et) if et in payload.EDGE_EMITTED_TYPES else et
            self.ev_tree.insert("", "end", values=(
                time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r.get("ts", 0))),
                r.get("camera", ""), what, self.tr("res_%s" % r.get("status", "queued"))))

    def _refresh(self):
        try:
            self._refresh_run()
            self._refresh_cams()
            self._refresh_events()
        except tk.TclError:
            pass
        self.root.after(3000, self._refresh)

    def on_close(self):
        if self.engine:
            self.engine.stop()
        self.root.destroy()


class CameraDialog:
    def __init__(self, app: App, cam):
        self.app, self.cam = app, cam
        t = app.tr
        self.win = w = tk.Toplevel(app.root)
        w.title(t("cam_dialog_title"))
        w.transient(app.root)
        self.name = tk.StringVar(value=cam.name if cam else "")
        self.url = tk.StringVar(value=cam.rtsp_url if cam else "rtsp://")
        self.user = tk.StringVar(value=(app.store.get(cam_key(cam.id, "user")) or "") if cam else "")
        self.pwd = tk.StringVar()      # never pre-filled: blank = keep existing
        self.ctok = tk.StringVar()
        self.enabled = tk.BooleanVar(value=cam.enabled if cam else True)
        rows = (("col_name", self.name, None), ("rtsp_label", self.url, None),
                ("user_label", self.user, None), ("pass_label", self.pwd, "•"),
                ("camtoken_label", self.ctok, "•"))
        for i, (key, var, show) in enumerate(rows):
            ttk.Label(w, text=t(key)).grid(row=i, column=0, sticky="w", **PAD)
            e = ttk.Entry(w, textvariable=var, width=48)
            if show:
                e.config(show=show)
            e.grid(row=i, column=1, sticky="we", **PAD)
        ttk.Label(w, text=t("rtsp_hint"), foreground="#555").grid(
            row=len(rows), column=1, sticky="w", **PAD)
        ttk.Checkbutton(w, text=t("enabled_label"), variable=self.enabled).grid(
            row=len(rows) + 1, column=1, sticky="w", **PAD)
        self.msg = ttk.Label(w, wraplength=420)
        self.msg.grid(row=len(rows) + 2, column=0, columnspan=2, sticky="w", **PAD)
        bf = ttk.Frame(w)
        bf.grid(row=len(rows) + 3, column=0, columnspan=2, sticky="e")
        ttk.Button(bf, text=t("test_btn"), command=self.test).pack(side="left", **PAD)
        ttk.Button(bf, text=t("save_btn"), command=self.save).pack(side="left", **PAD)
        ttk.Button(bf, text=t("cancel_btn"), command=w.destroy).pack(side="left", **PAD)

    def _creds(self):
        clean, u, p = split_rtsp_credentials(self.url.get())
        user = u or self.user.get().strip() or None
        pwd = p or self.pwd.get() or None
        if pwd is None and self.cam:
            pwd = self.app.store.get(cam_key(self.cam.id, "pass"))
        return clean, user, pwd

    def test(self):
        clean, user, pwd = self._creds()
        self.msg.config(text=self.app.tr("testing"))
        url = join_rtsp_credentials(clean, user, pwd)

        def done(res):
            if isinstance(res, tuple) and res[0]:
                self.msg.config(text=self.app.tr("test_ok", info=res[2]))
            else:
                self.msg.config(text=self.app.tr("test_fail"))
        self.app._bg(lambda: grab_one_frame(url), done)

    def save(self):
        clean, user, pwd = self._creds()
        name = self.name.get().strip()
        if not name or not clean.lower().startswith(("rtsp://", "rtsps://")):
            self.msg.config(text=self.app.tr("need_name_url"))
            return
        cam = self.cam or CameraConfig.new(name, clean)
        cam.name, cam.rtsp_url, cam.enabled = name[:120], clean, bool(self.enabled.get())
        if self.cam is None:
            self.app.cfg.cameras.append(cam)
        st = self.app.store
        st.set(cam_key(cam.id, "user"), user)
        if pwd:
            st.set(cam_key(cam.id, "pass"), pwd)
        if self.ctok.get().strip():
            st.set(cam_key(cam.id, "token"), self.ctok.get().strip())
        self.app.cstore.save(self.app.cfg)
        self.app._refresh_cams()
        self.win.destroy()


class ZoneEditor:
    """Click polygon points on a captured frame; saved normalised (0..1)."""

    def __init__(self, app: App, cam, frame):
        self.app, self.cam = app, cam
        t = app.tr
        self.win = w = tk.Toplevel(app.root)
        w.title(t("zone_title"))
        w.transient(app.root)
        self.photo, (self.h, self.w) = _frame_to_photo(frame)
        ttk.Label(w, text=t("zone_help"), wraplength=self.w).pack(**PAD)
        self.canvas = tk.Canvas(w, width=self.w, height=self.h, cursor="crosshair",
                                highlightthickness=0)
        self.canvas.pack()
        self.canvas.create_image(0, 0, image=self.photo, anchor="nw")
        self.points = [tuple(p) for p in (cam.zone or [])]
        self.canvas.bind("<Button-1>", self.click)
        bf = ttk.Frame(w)
        bf.pack(fill="x")
        self.msg = ttk.Label(bf)
        self.msg.pack(side="left", **PAD)
        for key, cmd in (("cancel_btn", w.destroy), ("save_btn", self.save),
                         ("clear_btn", self.clear), ("undo_btn", self.undo)):
            ttk.Button(bf, text=t(key), command=cmd).pack(side="right", **PAD)
        self.redraw()

    def click(self, ev):
        self.points.append((ev.x / float(self.w), ev.y / float(self.h)))
        self.redraw()

    def undo(self):
        if self.points:
            self.points.pop()
        self.redraw()

    def clear(self):
        self.points = []
        self.redraw()

    def redraw(self):
        self.canvas.delete("zone")
        px = [(x * self.w, y * self.h) for x, y in self.points]
        if len(px) >= 3:
            self.canvas.create_polygon(*[c for p in px for c in p], outline="#00c8ff",
                                       fill="", width=2, tags="zone")
        elif len(px) == 2:
            self.canvas.create_line(*[c for p in px for c in p], fill="#00c8ff",
                                    width=2, tags="zone")
        for x, y in px:
            self.canvas.create_oval(x - 4, y - 4, x + 4, y + 4, fill="#00c8ff",
                                    outline="white", tags="zone")

    def save(self):
        from .zone import normalize_polygon

        poly = normalize_polygon(self.points)
        if not poly:
            self.msg.config(text=self.app.tr("zone_need3"))
            return
        self.cam.zone = [[round(x, 4), round(y, 4)] for x, y in poly]
        self.app.cstore.save(self.app.cfg)
        self.app._refresh_cams()
        self.win.destroy()


def launch(cfg, cstore) -> int:
    root = tk.Tk()
    root.minsize(720, 640)
    app = App(root, cfg, cstore)
    root.protocol("WM_DELETE_WINDOW", app.on_close)
    root.mainloop()
    return 0
