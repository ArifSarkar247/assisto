"""Frozen AuraFace-v1 (Apache-2.0) as a torch module for the identity loss.
Uses onnx2torch (Apache-2.0) to convert glintr100.onnx. NOT RUN here.
Input: RGB 0..1 face crops (B,3,H,W) -> resized to 112x112, normalised like
core/photo_facelock.embed ((x*255-127.5)/127.5)."""
import torch


class AuraFaceTorch(torch.nn.Module):
    def __init__(self, onnx_path):
        super().__init__()
        from onnx2torch import convert
        self.net = convert(onnx_path)
        for p in self.net.parameters():
            p.requires_grad_(False)

    def forward(self, x):
        x = torch.nn.functional.interpolate(x, size=(112, 112), mode="bilinear", align_corners=False)
        x = (x * 255.0 - 127.5) / 127.5
        e = self.net(x)
        return torch.nn.functional.normalize(e, dim=1)
