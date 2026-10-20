"""Assisto Shop Box — edge client for shop loss-prevention (Part 4).

Runs on a shop PC on the SAME local network as the CCTV cameras. It pulls the
cameras' RTSP streams locally, runs small on-device detectors (motion, person in
the cash-drawer zone, after-hours activity) and sends ONLY a small JSON signal
plus at most one downscaled still snapshot to the Assisto server's
`shop/ingest` endpoint. Video never leaves the PC. The client opens no
listening ports: every network connection it makes is an outbound HTTPS request.
"""

__version__ = "0.1.0"
APP_NAME = "AssistoShopBox"
