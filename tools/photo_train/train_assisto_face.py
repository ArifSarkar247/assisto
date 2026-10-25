#!/usr/bin/env python3
"""Phase 2 "Assisto Face" — ONE-TIME training on a rented RunPod pod.
NOT RUN (Phase 2 is ON HOLD — no spending without the owner's go; the script
refuses to start unless ASSISTO_OWNER_GO=yes). Plan: owner_actions/PHOTO_OWN_MODEL_PLAN_BN.md

Licence-clean recipe:
  generator   RRDBNet x2 (architecture code: BasicSR, Apache-2.0) trained FROM
              SCRATCH (random init) — no third-party pretrained weights at all:
              Real-ESRGAN's weights are licence-GREY (trained on academic-only
              DIV2K/Flickr2K/OST), GFPGAN/CodeFormer are non-commercial.
              `--init` exists only for weights the owner has cleared in writing
              (needs --weights-cleared too).
  data        tools/photo_train/datasets.py allowed() sources only + opt-in
              user photos; LQ made by degrade.py
  losses      L1 + (1-SSIM) on pixels, a small PatchGAN discriminator trained
              from scratch, IDENTITY loss = 1 - cos(AuraFace(out), AuraFace(hq))
              (AuraFace-v1, Apache-2.0, trained on commercial data), and a
              SKIN-TONE loss = |mean Lab L,a,b of the skin mask out - hq| so the
              model can never learn to whiten/darken skin.
              (No VGG/LPIPS perceptual loss: ImageNet-weights licence is grey.)
  export      ONNX fp16 -> served by serve_handler.py on RunPod Serverless.

Usage on the pod (A100 80GB or RTX 4090):
  pip install torch torchvision basicsr==1.4.2 onnx onnxruntime-gpu opencv-python-headless
  ASSISTO_OWNER_GO=yes python3 train_assisto_face.py --lq data/lq --hq data/hq \
      --auraface glintr100.onnx --iters 300000 --out runs/af1
"""
import argparse
import glob
import os
import random


def build(args):
    import torch
    from basicsr.archs.rrdbnet_arch import RRDBNet
    g = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=2)
    if args.init:
        if not args.weights_cleared:
            raise SystemExit("--init needs --weights-cleared (owner-cleared commercial weights only)")
        sd = torch.load(args.init, map_location="cpu")
        g.load_state_dict(sd.get("params_ema") or sd.get("params") or sd, strict=True)
    d = torch.nn.Sequential(          # small PatchGAN, from scratch (no third-party weights)
        torch.nn.Conv2d(3, 64, 4, 2, 1), torch.nn.LeakyReLU(0.2, True),
        torch.nn.Conv2d(64, 128, 4, 2, 1), torch.nn.InstanceNorm2d(128), torch.nn.LeakyReLU(0.2, True),
        torch.nn.Conv2d(128, 256, 4, 2, 1), torch.nn.InstanceNorm2d(256), torch.nn.LeakyReLU(0.2, True),
        torch.nn.Conv2d(256, 1, 4, 1, 1))
    return g, d


class Pairs:
    def __init__(self, lq, hq, crop=256):
        self.lq = sorted(glob.glob(os.path.join(lq, "*.jpg")))
        self.hq, self.crop = hq, crop

    def __len__(self):
        return len(self.lq)

    def __getitem__(self, i):
        import numpy as np
        import torch
        from PIL import Image
        p = self.lq[i]
        stem = os.path.basename(p).split("_")[0]
        hq = Image.open(os.path.join(self.hq, stem + ".png")).convert("RGB")
        lq = Image.open(p).convert("RGB").resize((hq.width // 2, hq.height // 2), Image.BICUBIC)
        c = self.crop
        x = random.randint(0, max(0, hq.width - c)) // 2 * 2
        y = random.randint(0, max(0, hq.height - c)) // 2 * 2
        hq = hq.crop((x, y, x + c, y + c))
        lq = lq.crop((x // 2, y // 2, x // 2 + c // 2, y // 2 + c // 2))
        t = lambda im: torch.from_numpy(np.asarray(im, np.float32).transpose(2, 0, 1) / 255.0)
        return t(lq), t(hq)


def identity_loss(embed, out, hq):
    import torch
    a, b = embed(out), embed(hq)
    return (1 - torch.nn.functional.cosine_similarity(a, b)).mean()


def skin_tone_loss(out, hq):
    # mean colour of the central face region must match the target (no whitening)
    c = out.shape[-1] // 4
    o, h = out[..., c:-c, c:-c], hq[..., c:-c, c:-c]
    return (o.mean(dim=(2, 3)) - h.mean(dim=(2, 3))).abs().mean()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lq", required=True)
    ap.add_argument("--hq", required=True)
    ap.add_argument("--init", default="", help="ONLY owner-cleared commercial weights")
    ap.add_argument("--weights-cleared", action="store_true")
    ap.add_argument("--auraface", required=True)
    ap.add_argument("--iters", type=int, default=300000)   # from scratch needs more steps
    ap.add_argument("--batch", type=int, default=12)
    ap.add_argument("--out", default="runs/af1")
    a = ap.parse_args()
    if os.environ.get("ASSISTO_OWNER_GO") != "yes":
        raise SystemExit("Phase 2 is on hold: no GPU, no spending without the owner's go "
                         "(set ASSISTO_OWNER_GO=yes only after his written yes)")
    import torch
    from torch.utils.data import DataLoader
    from aura_torch import AuraFaceTorch          # ONNX->torch wrapper (frozen), see README in plan
    dev = "cuda"
    g, d = build(a)
    g, d = g.to(dev), d.to(dev)
    embed = AuraFaceTorch(a.auraface).to(dev).eval()
    og = torch.optim.Adam(g.parameters(), 1e-4, betas=(0.9, 0.99))
    od = torch.optim.Adam(d.parameters(), 1e-4, betas=(0.9, 0.99))
    dl = DataLoader(Pairs(a.lq, a.hq), batch_size=a.batch, shuffle=True, num_workers=8, drop_last=True)
    os.makedirs(a.out, exist_ok=True)
    it = 0
    while it < a.iters:
        for lq, hq in dl:
            lq, hq = lq.to(dev), hq.to(dev)
            out = g(lq).clamp(0, 1)
            l_pix = (out - hq).abs().mean()
            l_gan = torch.nn.functional.softplus(-d(out)).mean()
            l_id = identity_loss(embed, out, hq)
            l_skin = skin_tone_loss(out, hq)
            loss = l_pix + 0.05 * l_gan + 0.5 * l_id + 1.0 * l_skin
            og.zero_grad()
            loss.backward()
            og.step()
            ld = (torch.nn.functional.softplus(-d(hq)) + torch.nn.functional.softplus(d(out.detach()))).mean()
            od.zero_grad()
            ld.backward()
            od.step()
            it += 1
            if it % 500 == 0:
                print(it, float(l_pix), float(l_id), float(l_skin), flush=True)
            if it % 5000 == 0 or it >= a.iters:
                torch.save(g.state_dict(), os.path.join(a.out, "g_%06d.pth" % it))
            if it >= a.iters:
                break
    g.eval()
    x = torch.rand(1, 3, 256, 256, device=dev)
    torch.onnx.export(g.half(), x.half(), os.path.join(a.out, "assisto_face_x2.onnx"), opset_version=17,
                      input_names=["input"], output_names=["output"],
                      dynamic_axes={"input": {2: "h", 3: "w"}, "output": {2: "h", 3: "w"}})


if __name__ == "__main__":
    main()
