"""Streaming feature extraction — the SAME algorithm the phone runs
(app/android_overlay/.../voice/OwwEngine.kt). Train, evaluate and run with one
implementation so the numbers we report are the numbers the phone gets.

Two feature back-ends (chosen in config `features.backend`):

  "oww"  openWakeWord's split extractor: melspectrogram.onnx (raw int16-range
         audio -> 32-bin log-mel frames, 10 ms hop, then x/10 + 2) followed by
         embedding_model.onnx (76 mel frames -> one 96-d embedding).
  "e2e"  ONE model, Google speech_embedding (Apache-2.0, TF-Hub) converted to
         ONNX by rebuild_features.py: raw [-1, 1] audio window (window_samples)
         -> 96-d embedding. Licence-clean alternative; see MODEL_LICENSES.md.

Both produce one 96-d embedding every HOP = 1280 samples (80 ms). The wake
classifier sees the last `frames` (16) embeddings = 1.28 s.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass

import numpy as np

HOP = 1280  # 80 ms at 16 kHz
MEL_CONTEXT = 480  # 3 extra hops of 160 so the mel windows overlap the last chunk
MEL_WINDOW = 76  # mel frames per embedding (openWakeWord)
EMB_DIM = 96


def _session(path: str):
    import onnxruntime as ort  # MIT
    so = ort.SessionOptions()
    so.intra_op_num_threads = int(os.environ.get("WW_THREADS", "1"))
    so.inter_op_num_threads = 1
    return ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])


@dataclass
class FeatureSpec:
    backend: str  # "oww" | "e2e"
    mel_path: str = ""
    embed_path: str = ""
    e2e_path: str = ""
    window_samples: int = 12400  # e2e only

    @staticmethod
    def load(d: dict, base: str = "") -> "FeatureSpec":
        j = lambda p: os.path.join(base, p) if p and not os.path.isabs(p) else p  # noqa: E731
        return FeatureSpec(backend=d["backend"], mel_path=j(d.get("mel", "")),
                           embed_path=j(d.get("embed", "")), e2e_path=j(d.get("e2e", "")),
                           window_samples=int(d.get("window_samples", 12400)))


class StreamingFeatures:
    """Feed 16 kHz float audio ([-1, 1]) in any chunk sizes; get embeddings.

    Mirrors OwwEngine.kt: audio is consumed in HOP-sized steps; each step
    yields exactly one embedding once enough context has been seen."""

    def __init__(self, spec: FeatureSpec):
        self.spec = spec
        if spec.backend == "oww":
            self._mel = _session(spec.mel_path)
            self._emb = _session(spec.embed_path)
            self._mel_in = self._mel.get_inputs()[0].name
            self._emb_in = self._emb.get_inputs()[0].name
        elif spec.backend == "e2e":
            self._e2e = _session(spec.e2e_path)
            self._e2e_in = self._e2e.get_inputs()[0].name
        else:
            raise ValueError("unknown feature backend " + spec.backend)
        self.reset()

    def reset(self):
        self._pending = np.zeros(0, dtype=np.float32)
        keep = MEL_CONTEXT + HOP if self.spec.backend == "oww" else self.spec.window_samples
        self._audio = np.zeros(keep, dtype=np.float32)  # rolling raw audio
        self._mel_frames = np.zeros((0, 32), dtype=np.float32)
        self._seen = 0
        self.emit_samples = []  # sample index (end of audio) of each embedding pushed last

    # -- one HOP ---------------------------------------------------------------
    def _step(self, chunk: np.ndarray):
        self._audio = np.concatenate([self._audio[len(chunk):], chunk])
        self._seen += len(chunk)
        if self.spec.backend == "oww":
            x = (self._audio * 32767.0).astype(np.float32)[None, :]
            mel = self._mel.run(None, {self._mel_in: x})[0]
            mel = np.squeeze(mel).reshape(-1, 32) / 10.0 + 2.0
            self._mel_frames = np.concatenate([self._mel_frames, mel.astype(np.float32)])[-MEL_WINDOW * 2:]
            if len(self._mel_frames) < MEL_WINDOW:
                return None
            win = self._mel_frames[-MEL_WINDOW:][None, :, :, None]
            e = self._emb.run(None, {self._emb_in: win.astype(np.float32)})[0]
            return np.reshape(e, (-1, EMB_DIM))[-1]
        if self._seen < self.spec.window_samples:
            return None
        e = self._e2e.run(None, {self._e2e_in: self._audio[None, :].astype(np.float32)})[0]
        return np.reshape(e, (-1, EMB_DIM))[-1]

    def push(self, audio: np.ndarray) -> np.ndarray:
        """Returns the new embeddings [k, 96] produced by this audio."""
        self._pending = np.concatenate([self._pending, audio.astype(np.float32)])
        out = []
        self.emit_samples = []
        while len(self._pending) >= HOP:
            chunk, self._pending = self._pending[:HOP], self._pending[HOP:]
            e = self._step(chunk)
            if e is not None:
                out.append(e)
                self.emit_samples.append(self._seen)
        return np.asarray(out, dtype=np.float32).reshape(-1, EMB_DIM)

    def clip_embeddings(self, audio: np.ndarray) -> np.ndarray:
        self.reset()
        return self.push(audio)


def windows(emb: np.ndarray, frames: int, stride: int = 1) -> np.ndarray:
    """All [frames, 96] windows of an embedding sequence -> [n, frames, 96]."""
    if len(emb) < frames:
        return np.zeros((0, frames, EMB_DIM), dtype=np.float32)
    idx = np.arange(0, len(emb) - frames + 1, stride)
    return np.stack([emb[i: i + frames] for i in idx]).astype(np.float32)


# ---- tiny fake extractor for unit tests / smoke runs (no downloads) ---------

def make_fake_e2e(path: str, window_samples: int = 2560, seed: int = 0) -> None:
    """A deterministic random-projection "embedding" model with the e2e I/O
    contract ([1, W] -> [1, 1, 1, 96]). Used ONLY by tests and the local
    smoke run; it is never shipped."""
    import onnx
    from onnx import TensorProto, helper, numpy_helper
    rng = np.random.default_rng(seed)
    w = (rng.standard_normal((window_samples, EMB_DIM)) / np.sqrt(window_samples)).astype(np.float32)
    nodes = [
        helper.make_node("Abs", ["audio"], ["a"]),
        helper.make_node("MatMul", ["a", "W"], ["m"]),
        helper.make_node("Tanh", ["m"], ["t"]),
        helper.make_node("Reshape", ["t", "shape"], ["embedding"]),
    ]
    g = helper.make_graph(
        nodes, "fake_e2e",
        [helper.make_tensor_value_info("audio", TensorProto.FLOAT, [1, window_samples])],
        [helper.make_tensor_value_info("embedding", TensorProto.FLOAT, [1, 1, 1, EMB_DIM])],
        [numpy_helper.from_array(w, "W"),
         numpy_helper.from_array(np.array([1, 1, 1, EMB_DIM], dtype=np.int64), "shape")])
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)])
    m.ir_version = 8
    onnx.checker.check_model(m)
    onnx.save(m, path)


def write_spec(path: str, spec: FeatureSpec) -> None:
    with open(path, "w") as f:
        json.dump({"backend": spec.backend, "mel": spec.mel_path, "embed": spec.embed_path,
                   "e2e": spec.e2e_path, "window_samples": spec.window_samples}, f, indent=1)
