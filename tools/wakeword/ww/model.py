"""Small wake-word classifier (numpy only) + ONNX export.

Input: the last `frames` (16) speech embeddings [frames, 96] = 1.28 s.
Net:   standardise -> Dense(h) -> ReLU -> Dense(h) -> ReLU -> Dense(1) -> sigmoid
       (the openWakeWord "DNN" head, without LayerNorm so the ONNX graph only
       needs opset-13 ops that ONNX Runtime Mobile runs everywhere).
Training: Adam, balanced mini-batches, negative-class weight ramp (fewer false
accepts, the openWakeWord recipe) and hard-negative mining.
Pure numpy so it runs in CI without torch and is unit-testable on tiny data.
"""
from __future__ import annotations

import numpy as np


class WakeNet:
    def __init__(self, frames: int = 16, dim: int = 96, hidden: int = 64, seed: int = 0):
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

    def predict(self, x: np.ndarray, batch: int = 4096) -> np.ndarray:
        out = [1.0 / (1.0 + np.exp(-np.clip(self.forward(x[i: i + batch]), -30, 30)))
               for i in range(0, len(x), batch)]
        return np.concatenate(out) if out else np.zeros(0, np.float32)

    # -- training ---------------------------------------------------------------
    def fit(self, pos: np.ndarray, neg: np.ndarray, steps: int = 3000, batch: int = 512,
            lr: float = 1e-3, max_neg_weight: float = 20.0, seed: int = 0,
            log=lambda s: None, val=None) -> dict:
        rng = np.random.default_rng(seed)
        sub = neg[rng.integers(0, len(neg), min(len(neg), 50000))]
        allx = np.concatenate([pos[: 20000].astype(np.float32), sub.astype(np.float32)]).reshape(
            -1, self.frames * self.dim)
        self.mu = allx.mean(0).astype(np.float32)
        self.sd = (allx.std(0) + 1e-3).astype(np.float32)
        del allx
        m = {k: np.zeros_like(v) for k, v in self.p.items()}
        v = {k: np.zeros_like(v) for k, v in self.p.items()}
        b1, b2, eps = 0.9, 0.999, 1e-8
        neg_score = np.zeros(len(neg), np.float32)  # for hard-negative mining
        hist = []
        half = batch // 2
        for t in range(1, steps + 1):
            ip = rng.integers(0, len(pos), half)
            if t > steps // 3 and t % 2 == 0:
                # half of later batches: the negatives the model scores highest
                k = min(len(neg), half * 8)
                cand = rng.integers(0, len(neg), k)
                ineg = cand[np.argsort(-neg_score[cand])[:half]]
            else:
                ineg = rng.integers(0, len(neg), half)
            x = np.concatenate([pos[ip], neg[ineg]]).astype(np.float32)
            y = np.concatenate([np.ones(half, np.float32), np.zeros(half, np.float32)])
            wneg = 1.0 + (max_neg_weight - 1.0) * min(1.0, t / max(1, steps * 0.6))
            w = np.where(y > 0, 1.0, wneg).astype(np.float32)
            logit, (z0, a1, h1, a2, h2) = self.forward(x, keep=True)
            prob = 1.0 / (1.0 + np.exp(-np.clip(logit, -30, 30)))
            neg_score[ineg] = prob[half:]
            g = (w * (prob - y) / w.sum())[:, None].astype(np.float32)  # dL/dlogit
            grads = {"W3": h2.T @ g, "b3": g.sum(0)}
            d2 = (g @ self.p["W3"].T) * (a2 > 0)
            grads["W2"], grads["b2"] = h1.T @ d2, d2.sum(0)
            d1 = (d2 @ self.p["W2"].T) * (a1 > 0)
            grads["W1"], grads["b1"] = z0.T @ d1, d1.sum(0)
            for k in self.p:
                gk = grads[k].astype(np.float32) + (1e-5 * self.p[k] if k.startswith("W") else 0)
                m[k] = b1 * m[k] + (1 - b1) * gk
                v[k] = b2 * v[k] + (1 - b2) * gk * gk
                mh = m[k] / (1 - b1 ** t)
                vh = v[k] / (1 - b2 ** t)
                self.p[k] -= (lr * mh / (np.sqrt(vh) + eps)).astype(np.float32)
            if t % max(1, steps // 10) == 0 or t == steps:
                loss = float(-(w * (y * np.log(prob + 1e-7) + (1 - y) * np.log(1 - prob + 1e-7))).sum() / w.sum())
                row = {"step": t, "loss": round(loss, 5), "neg_weight": round(wneg, 2)}
                if val is not None:
                    vp, vn = val
                    row["val_recall@0.5"] = round(float((self.predict(vp) >= 0.5).mean()), 4) if len(vp) else None
                    row["val_neg_fp@0.5"] = round(float((self.predict(vn) >= 0.5).mean()), 6) if len(vn) else None
                hist.append(row)
                log(row)
        return {"history": hist}

    # -- ONNX -------------------------------------------------------------------
    def to_onnx(self, path: str) -> None:
        """input "input" [1, frames, 96] float32 -> output "score" [1, 1]."""
        import onnx
        from onnx import TensorProto, helper, numpy_helper
        n = self.frames * self.dim
        inits = [numpy_helper.from_array(a.astype(np.float32), k) for k, a in self.p.items()]
        inits += [numpy_helper.from_array(self.mu, "mu"), numpy_helper.from_array(self.sd, "sd"),
                  numpy_helper.from_array(np.array([-1, n], dtype=np.int64), "flat")]
        nodes = [
            helper.make_node("Reshape", ["input", "flat"], ["x0"]),
            helper.make_node("Sub", ["x0", "mu"], ["x1"]),
            helper.make_node("Div", ["x1", "sd"], ["x2"]),
            helper.make_node("Gemm", ["x2", "W1", "b1"], ["a1"]),
            helper.make_node("Relu", ["a1"], ["h1"]),
            helper.make_node("Gemm", ["h1", "W2", "b2"], ["a2"]),
            helper.make_node("Relu", ["a2"], ["h2"]),
            helper.make_node("Gemm", ["h2", "W3", "b3"], ["a3"]),
            helper.make_node("Sigmoid", ["a3"], ["score"]),
        ]
        g = helper.make_graph(
            nodes, "assisto_wake",
            [helper.make_tensor_value_info("input", TensorProto.FLOAT, ["N", self.frames, self.dim])],
            [helper.make_tensor_value_info("score", TensorProto.FLOAT, ["N", 1])], inits)
        mdl = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)],
                                producer_name="assisto-wakeword")
        mdl.ir_version = 8  # loadable by ONNX Runtime >= 1.14
        onnx.checker.check_model(mdl)
        onnx.save(mdl, path)

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
