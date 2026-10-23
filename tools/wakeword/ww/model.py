"""Small wake-word classifier (numpy only) + ONNX export.

Member net (WakeNet), input = `frames` speech embeddings [frames, 96]:
    standardise -> Dense(h) -> ReLU -> Dense(h) -> ReLU -> Dense(1)   (= a logit)
The SHIPPED classifier (Scorer) keeps the app's contract — input [N, 16, 96]
(the last 16 embeddings = 1.28 s), output "score" [N, 1] in (0, 1) — and is:
    logit = min over k shifts s of  mean over members m of  net_m(x[:, s : s+sub])
    score = sigmoid(logit / T)
  * k shifts (sub = 16 - k + 1 frames): in-graph smoothing — the phrase must be
    seen in k consecutive 80 ms positions (like "patience", but stateless, so the
    app's decider code does not change);
  * members: an ensemble of seeds (averaged logits) — lower run-to-run variance;
  * T: a monotone temperature so the picked thresholds stay well inside float32
    range on the phone (ranking, and therefore every FA/FRR number, is unchanged).
ONNX ops: Slice, Reshape, Sub, Div, Gemm, Relu, Sum, Mul, Min, Sigmoid (opset 13;
ONNX Runtime Mobile 1.23.2 runs all of them).

Training (train()): Adam with warm-up + cosine learning-rate schedule, an
exponential moving average (EMA) of the weights, balanced batches, a ramped
negative-class weight, hard-negative MINING over the whole negative pool with
the current model (several rounds), and checkpoint selection on VALIDATION
(recall at the validation false-accept target), never on the test sets.
Pure numpy so it runs in CI without torch and is unit-testable on tiny data.
"""
from __future__ import annotations

import copy

import numpy as np

EMB = 96


def _sig(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -60, 60)))


class WakeNet:
    def __init__(self, frames: int = 16, dim: int = EMB, hidden: int = 64, seed: int = 0):
        rng = np.random.default_rng(seed)
        n = frames * dim
        self.frames, self.dim, self.hidden = frames, dim, hidden
        he = lambda a, b: (rng.standard_normal((a, b)) * np.sqrt(2.0 / a)).astype(np.float32)  # noqa: E731
        self.p = {
            "W1": he(n, hidden), "b1": np.zeros(hidden, np.float32),
            "W2": he(hidden, hidden), "b2": np.zeros(hidden, np.float32),
            "W3": (rng.standard_normal((hidden, 1)) * 0.01).astype(np.float32),
            "b3": np.zeros(1, np.float32),
        }
        self.mu = np.zeros(n, np.float32)
        self.sd = np.ones(n, np.float32)

    # -- forward ----------------------------------------------------------------
    def _flat(self, x: np.ndarray) -> np.ndarray:
        x = x.reshape(len(x), -1).astype(np.float32)
        return (x - self.mu) / self.sd

    def forward(self, x: np.ndarray, keep: bool = False):
        p = self.p
        z0 = self._flat(x)
        a1 = z0 @ p["W1"] + p["b1"]
        h1 = np.maximum(a1, 0)
        a2 = h1 @ p["W2"] + p["b2"]
        h2 = np.maximum(a2, 0)
        logit = (h2 @ p["W3"] + p["b3"])[:, 0]
        if keep:
            return logit, (z0, a1, h1, a2, h2)
        return logit

    def logits(self, x: np.ndarray, batch: int = 8192) -> np.ndarray:
        out = [self.forward(x[i: i + batch]) for i in range(0, len(x), batch)]
        return np.concatenate(out).astype(np.float32) if out else np.zeros(0, np.float32)

    def predict(self, x: np.ndarray, batch: int = 4096) -> np.ndarray:
        return _sig(self.logits(x, batch)).astype(np.float32)

    def stream_logits(self, emb: np.ndarray, chunk: int = 200000) -> np.ndarray:
        """Logit of every window emb[j : j+frames] (j = 0 .. T-frames) without
        materialising the windows: layer 1 = sum over frames of per-frame
        projections."""
        T = len(emb)
        n = T - self.frames + 1
        if n <= 0:
            return np.zeros(0, np.float32)
        W1 = self.p["W1"].reshape(self.frames, self.dim, self.hidden)
        mu = self.mu.reshape(self.frames, self.dim)
        sd = self.sd.reshape(self.frames, self.dim)
        out = np.zeros(n, np.float32)
        for a in range(0, n, chunk):
            b = min(n, a + chunk)
            E = emb[a: b + self.frames - 1].astype(np.float32)
            a1 = np.zeros((b - a, self.hidden), np.float32) + self.p["b1"]
            for f in range(self.frames):
                a1 += ((E[f: f + (b - a)] - mu[f]) / sd[f]) @ W1[f]
            h1 = np.maximum(a1, 0)
            h2 = np.maximum(h1 @ self.p["W2"] + self.p["b2"], 0)
            out[a:b] = (h2 @ self.p["W3"] + self.p["b3"])[:, 0]
        return out

    # -- training (compat wrapper) --------------------------------------------
    def fit(self, pos: np.ndarray, neg: np.ndarray, steps: int = 3000, batch: int = 512,
            lr: float = 1e-3, max_neg_weight: float = 20.0, seed: int = 0,
            log=lambda s: None, val=None, **kw) -> dict:
        """pos/neg: [n, frames, 96] windows of exactly self.frames."""
        pp = FramePool.from_parts([pos], [], self.frames)
        npool = FramePool.from_parts([neg], [], self.frames)
        cfg = dict(steps=steps, batch=batch, lr=lr, max_neg_weight=max_neg_weight, seed=seed)
        cfg.update(kw)
        return train(self, pp, npool, cfg, val_fn=None, log=log)

    # -- io ---------------------------------------------------------------------
    def save_npz(self, path: str) -> None:
        np.savez_compressed(path, mu=self.mu, sd=self.sd, frames=self.frames, dim=self.dim,
                            hidden=self.hidden, **self.p)

    @staticmethod
    def load_npz(path: str) -> "WakeNet":
        z = np.load(path)
        net = WakeNet(int(z["frames"]), int(z["dim"]), int(z["hidden"]))
        net.mu, net.sd = z["mu"], z["sd"]
        for k in net.p:
            net.p[k] = z[k]
        return net

    def to_onnx(self, path: str) -> None:
        Scorer([self], frames=self.frames).to_onnx(path)


# ---- pools of training windows (no materialised windows) -----------------------

class FramePool:
    """All windows of length `frames` from a set of embedding sequences, as start
    indices into ONE frame array E (windows never cross a sequence boundary).
    kind[i] = 0 for windows cut from clip windows, 1 for long streams."""

    def __init__(self, E, starts, kind, frames):
        self.E, self.starts, self.kind, self.frames = E, starts, kind, frames
        self._ar = np.arange(frames)
        self._by_kind = {k: np.nonzero(kind == k)[0] for k in (0, 1)}

    @staticmethod
    def from_parts(window_sets, streams, frames: int, dtype=np.float16) -> "FramePool":
        blocks, starts, kinds, base = [], [], [], 0
        for w in window_sets:
            if not len(w):
                continue
            n, F, D = w.shape
            if F < frames:
                raise ValueError("window shorter than frames")
            blocks.append(np.asarray(w, dtype).reshape(n * F, D))
            st = (base + np.arange(n)[:, None] * F + np.arange(F - frames + 1)[None, :]).ravel()
            starts.append(st)
            kinds.append(np.zeros(len(st), np.int8))
            base += n * F
        for s in streams:
            if len(s) < frames:
                continue
            blocks.append(np.asarray(s, dtype))
            st = base + np.arange(len(s) - frames + 1)
            starts.append(st)
            kinds.append(np.ones(len(st), np.int8))
            base += len(s)
        E = np.concatenate(blocks) if blocks else np.zeros((0, EMB), dtype)
        st = np.concatenate(starts).astype(np.int64) if starts else np.zeros(0, np.int64)
        kd = np.concatenate(kinds) if kinds else np.zeros(0, np.int8)
        return FramePool(E, st, kd, frames)

    def __len__(self):
        return len(self.starts)

    def gather(self, idx) -> np.ndarray:
        return self.E[self.starts[idx][:, None] + self._ar].astype(np.float32)

    def sample(self, rng, n, kind=None):
        if kind is None:
            return rng.integers(0, len(self), n)
        pool = self._by_kind.get(kind)
        if pool is None or not len(pool):
            return rng.integers(0, len(self), n)
        return pool[rng.integers(0, len(pool), n)]

    def all_logits(self, net: "WakeNet", batch: int = 32768) -> np.ndarray:
        out = np.zeros(len(self), np.float32)
        for a in range(0, len(self), batch):
            out[a: a + batch] = net.forward(self.gather(np.arange(a, min(len(self), a + batch))))
        return out


def lr_at(t: int, steps: int, lr: float, warmup: int, min_frac: float) -> float:
    if t <= warmup:
        return lr * t / max(1, warmup)
    q = (t - warmup) / max(1, steps - warmup)
    return lr * (min_frac + (1 - min_frac) * 0.5 * (1 + np.cos(np.pi * min(1.0, q))))


def train(net: WakeNet, pos: FramePool, neg: FramePool, cfg: dict, val_fn=None,
          log=lambda s: None) -> dict:
    """cfg: steps, batch, lr, warmup, lr_min_frac, max_neg_weight, ema, l2, dropout, input_noise,
    mine_at (fractions of steps), mine_k, mine_frac, clip_frac, eval_every,
    select_after (fraction), seed.  val_fn(net) -> dict with key "select"
    (higher is better). The best EMA checkpoint (by val) is loaded into `net`."""
    g = lambda k, d: cfg.get(k, d)  # noqa: E731
    steps, batch, lr = int(g("steps", 3000)), int(g("batch", 512)), float(g("lr", 1e-3))
    warmup = int(g("warmup", max(1, steps // 20)))
    min_frac = float(g("lr_min_frac", 0.05))
    max_w = float(g("max_neg_weight", 20.0))
    ema_d = float(g("ema", 0.0))
    l2 = float(g("l2", 1e-5))
    mine_at = sorted(int(f * steps) for f in g("mine_at", []))
    mine_k = int(g("mine_k", 20000))
    mine_frac = float(g("mine_frac", 0.4))
    clip_frac = float(g("clip_frac", 0.25))
    eval_every = int(g("eval_every", max(1, steps // 10)))
    select_after = int(float(g("select_after", 0.3)) * steps)
    drop = float(g("dropout", 0.0))
    in_noise = float(g("input_noise", 0.0))
    rng = np.random.default_rng(int(g("seed", 0)))

    # standardisation from a sample of both classes
    sp = pos.gather(pos.sample(rng, min(len(pos), 20000)))
    sn = neg.gather(neg.sample(rng, min(len(neg), 50000)))
    allx = np.concatenate([sp, sn]).reshape(-1, net.frames * net.dim)
    net.mu = allx.mean(0).astype(np.float32)
    net.sd = (allx.std(0) + 1e-3).astype(np.float32)
    del allx, sp, sn
    m = {k: np.zeros_like(v) for k, v in net.p.items()}
    v = {k: np.zeros_like(v) for k, v in net.p.items()}
    ema = {k: v_.copy() for k, v_ in net.p.items()} if ema_d > 0 else None
    b1, b2, eps = 0.9, 0.999, 1e-8
    neg_score = np.full(len(neg), -1e9, np.float32)  # online scores (old recipe)
    mined = np.zeros(0, np.int64)
    hist, mining = [], []
    best = None
    half = batch // 2

    def ema_net():
        if ema is None:
            return net
        e = copy.copy(net)
        e.p = {k: a.copy() for k, a in ema.items()}
        return e

    for t in range(1, steps + 1):
        if mine_at and t == mine_at[0]:
            mine_at.pop(0)
            sc = neg.all_logits(ema_net())
            k = min(mine_k, len(sc))
            mined = np.argpartition(-sc, k - 1)[:k] if k else mined
            mining.append({"step": t, "k": int(k), "min_logit_mined": round(float(sc[mined].min()), 3)
                           if k else None, "max_logit": round(float(sc.max()), 3),
                           "n_above_0": int((sc > 0).sum())})
            log({"mine": mining[-1]})
        ip = pos.sample(rng, half)
        n_m = int(half * mine_frac) if len(mined) else 0
        n_c = int(half * clip_frac)
        n_r = half - n_m - n_c
        parts = [neg.sample(rng, n_c, kind=0), neg.sample(rng, n_r, kind=1)]
        if n_m:
            parts.append(mined[rng.integers(0, len(mined), n_m)])
        elif t > steps // 3 and t % 2 == 0:
            cand = rng.integers(0, len(neg), min(len(neg), half * 8))
            parts.append(cand[np.argsort(-neg_score[cand])[: max(0, n_r // 2)]])
            parts[1] = parts[1][: n_r - len(parts[-1])]
        ineg = np.concatenate(parts)
        x = np.concatenate([pos.gather(ip), neg.gather(ineg)])
        y = np.concatenate([np.ones(half, np.float32), np.zeros(len(ineg), np.float32)])
        wneg = 1.0 + (max_w - 1.0) * min(1.0, t / max(1, steps * 0.6))
        w = np.where(y > 0, 1.0, wneg).astype(np.float32)
        # forward with (optional) input noise on the standardised input + dropout
        P = net.p
        z0 = net._flat(x)
        if in_noise > 0:
            z0 = z0 + rng.standard_normal(z0.shape, dtype=np.float32) * np.float32(in_noise)
        a1 = z0 @ P["W1"] + P["b1"]
        m1 = ((rng.random(a1.shape, dtype=np.float32) >= drop) / np.float32(1 - drop)) if drop > 0 else 1.0
        h1 = np.maximum(a1, 0) * m1
        a2 = h1 @ P["W2"] + P["b2"]
        m2 = ((rng.random(a2.shape, dtype=np.float32) >= drop) / np.float32(1 - drop)) if drop > 0 else 1.0
        h2 = np.maximum(a2, 0) * m2
        logit = (h2 @ P["W3"] + P["b3"])[:, 0]
        prob = _sig(logit).astype(np.float32)
        neg_score[ineg] = logit[half:]
        gl = (w * (prob - y) / w.sum())[:, None].astype(np.float32)
        grads = {"W3": h2.T @ gl, "b3": gl.sum(0)}
        d2 = (gl @ P["W3"].T) * (a2 > 0) * m2
        grads["W2"], grads["b2"] = h1.T @ d2, d2.sum(0)
        d1 = (d2 @ P["W2"].T) * (a1 > 0) * m1
        grads["W1"], grads["b1"] = z0.T @ d1, d1.sum(0)
        lr_t = lr_at(t, steps, lr, warmup, min_frac)
        for k in net.p:
            gk = grads[k].astype(np.float32) + (l2 * net.p[k] if k.startswith("W") else 0)
            m[k] = b1 * m[k] + (1 - b1) * gk
            v[k] = b2 * v[k] + (1 - b2) * gk * gk
            mh = m[k] / (1 - b1 ** t)
            vh = v[k] / (1 - b2 ** t)
            net.p[k] -= (lr_t * mh / (np.sqrt(vh) + eps)).astype(np.float32)
            if ema is not None:
                d = min(ema_d, (1 + t) / (10 + t))
                ema[k] = d * ema[k] + (1 - d) * net.p[k]
        if t % eval_every == 0 or t == steps:
            loss = float(-(w * (y * np.log(prob + 1e-7) + (1 - y) * np.log(1 - prob + 1e-7))).sum() / w.sum())
            row = {"step": t, "loss": round(loss, 5), "neg_weight": round(wneg, 2), "lr": round(lr_t, 6)}
            if val_fn is not None:
                en = ema_net()
                vr = val_fn(en)
                row.update({k: vr[k] for k in vr if k != "select"})
                row["select"] = vr["select"]
                if t >= select_after and (best is None or vr["select"] >= best[0]):
                    best = (vr["select"], t, {k: a.copy() for k, a in en.p.items()})
            hist.append(row)
            log(row)
    if best is not None:
        net.p = best[2]
        chosen = best[1]
    else:
        if ema is not None:
            net.p = {k: a.copy() for k, a in ema.items()}
        chosen = steps
    return {"history": hist, "mining": mining, "chosen_step": chosen}


# ---- shipped classifier ------------------------------------------------------------

class Scorer:
    """Ensemble x in-graph smoothing x temperature (see module doc)."""

    def __init__(self, members, frames: int = 16, temperature: float = 1.0):
        self.members = list(members)
        self.frames = frames
        self.sub = self.members[0].frames
        self.k = frames - self.sub + 1
        if self.k < 1 or any(m.frames != self.sub for m in self.members):
            raise ValueError("members must share frames <= Scorer frames")
        self.T = float(temperature)

    def window_logits(self, x: np.ndarray) -> np.ndarray:
        """x [n, frames, 96] -> final logits (before temperature)."""
        per_s = [np.mean([m.logits(x[:, s: s + self.sub]) for m in self.members], axis=0)
                 for s in range(self.k)]
        return np.min(np.stack(per_s), axis=0).astype(np.float32)

    def stream_logits(self, emb: np.ndarray, cache: dict | None = None, key=None) -> np.ndarray:
        """Final logit of every 16-frame window of an embedding stream
        (index i = window emb[i : i+frames], i.e. score at frame i+frames-1)."""
        Ls = []
        for m in self.members:
            ck = (key, id(m))
            if cache is not None and key is not None and ck in cache:
                Ls.append(cache[ck])
                continue
            L = m.stream_logits(emb)
            if cache is not None and key is not None:
                cache[ck] = L
            Ls.append(L)
        Lbar = np.mean(Ls, axis=0)
        n = len(emb) - self.frames + 1
        if n <= 0:
            return np.zeros(0, np.float32)
        return np.min(np.stack([Lbar[s: s + n] for s in range(self.k)]), axis=0).astype(np.float32)

    def to_score(self, logit: np.ndarray) -> np.ndarray:
        """Exactly the ONNX tail: Mul(1/T) then Sigmoid, in float32."""
        z = (np.asarray(logit, np.float32) * np.float32(1.0 / self.T)).astype(np.float32)
        return (np.float32(1.0) / (np.float32(1.0) + np.exp(-np.clip(z, -80, 80)))).astype(np.float32)

    def predict(self, x: np.ndarray) -> np.ndarray:
        return self.to_score(self.window_logits(x))

    def save_npz(self, path: str) -> None:
        d = {"frames": self.frames, "T": self.T, "n": len(self.members)}
        for i, m in enumerate(self.members):
            d.update({f"m{i}_{k}": v for k, v in m.p.items()})
            d[f"m{i}_mu"], d[f"m{i}_sd"] = m.mu, m.sd
            d[f"m{i}_meta"] = np.array([m.frames, m.dim, m.hidden])
        np.savez_compressed(path, **d)

    @staticmethod
    def load_npz(path: str) -> "Scorer":
        z = np.load(path)
        ms = []
        for i in range(int(z["n"])):
            fr, dim, hid = [int(a) for a in z[f"m{i}_meta"]]
            m = WakeNet(fr, dim, hid)
            m.mu, m.sd = z[f"m{i}_mu"], z[f"m{i}_sd"]
            for k in m.p:
                m.p[k] = z[f"m{i}_{k}"]
            ms.append(m)
        return Scorer(ms, int(z["frames"]), float(z["T"]))

    def to_onnx(self, path: str) -> None:
        """input "input" [N, frames, 96] float32 -> output "score" [N, 1]."""
        import onnx
        from onnx import TensorProto, helper, numpy_helper
        sub, D = self.sub, self.members[0].dim
        inits = [numpy_helper.from_array(np.array([-1, sub * D], np.int64), "flat"),
                 numpy_helper.from_array(np.array([1], np.int64), "ax1")]
        nodes = []
        for i, m in enumerate(self.members):
            for k, a in m.p.items():
                inits.append(numpy_helper.from_array(a.astype(np.float32), f"m{i}_{k}"))
            inits += [numpy_helper.from_array(m.mu.astype(np.float32), f"m{i}_mu"),
                      numpy_helper.from_array(m.sd.astype(np.float32), f"m{i}_sd")]
        shift_outs = []
        for s in range(self.k):
            src = "input"
            if self.k > 1:
                inits += [numpy_helper.from_array(np.array([s], np.int64), f"s{s}_a"),
                          numpy_helper.from_array(np.array([s + sub], np.int64), f"s{s}_b")]
                nodes.append(helper.make_node("Slice", ["input", f"s{s}_a", f"s{s}_b", "ax1"], [f"s{s}_x"]))
                src = f"s{s}_x"
            nodes.append(helper.make_node("Reshape", [src, "flat"], [f"s{s}_f"]))
            outs = []
            for i in range(len(self.members)):
                p = f"s{s}m{i}"
                nodes += [
                    helper.make_node("Sub", [f"s{s}_f", f"m{i}_mu"], [p + "_c"]),
                    helper.make_node("Div", [p + "_c", f"m{i}_sd"], [p + "_z"]),
                    helper.make_node("Gemm", [p + "_z", f"m{i}_W1", f"m{i}_b1"], [p + "_a1"]),
                    helper.make_node("Relu", [p + "_a1"], [p + "_h1"]),
                    helper.make_node("Gemm", [p + "_h1", f"m{i}_W2", f"m{i}_b2"], [p + "_a2"]),
                    helper.make_node("Relu", [p + "_a2"], [p + "_h2"]),
                    helper.make_node("Gemm", [p + "_h2", f"m{i}_W3", f"m{i}_b3"], [p + "_l"]),
                ]
                outs.append(p + "_l")
            if len(outs) > 1:
                inits.append(numpy_helper.from_array(np.array([1.0 / len(outs)], np.float32), f"s{s}_inv"))
                nodes += [helper.make_node("Sum", outs, [f"s{s}_sum"]),
                          helper.make_node("Mul", [f"s{s}_sum", f"s{s}_inv"], [f"s{s}_l"])]
                shift_outs.append(f"s{s}_l")
            else:
                shift_outs.append(outs[0])
        if len(shift_outs) > 1:
            nodes.append(helper.make_node("Min", shift_outs, ["logit"]))
            last = "logit"
        else:
            last = shift_outs[0]
        if self.T != 1.0:
            inits.append(numpy_helper.from_array(np.array([1.0 / self.T], np.float32), "invT"))
            nodes.append(helper.make_node("Mul", [last, "invT"], ["logit_t"]))
            last = "logit_t"
        nodes.append(helper.make_node("Sigmoid", [last], ["score"]))
        g = helper.make_graph(
            nodes, "assisto_wake",
            [helper.make_tensor_value_info("input", TensorProto.FLOAT, ["N", self.frames, D])],
            [helper.make_tensor_value_info("score", TensorProto.FLOAT, ["N", 1])], inits)
        mdl = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)],
                                producer_name="assisto-wakeword")
        mdl.ir_version = 8  # loadable by ONNX Runtime >= 1.14
        onnx.checker.check_model(mdl)
        onnx.save(mdl, path)
