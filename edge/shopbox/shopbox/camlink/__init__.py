"""camlink — the LAN camera library of the Assisto Guard Box (CCTV Guard V3,
agent cctvconnect; the Guard Box runtime itself is agent cctvbox's).

  discovery    ONVIF WS-Discovery + Hikvision SADP + Dahua DHIP, merged by IP
  isapi        Hikvision ISAPI: device, working status, disks, IP channels,
               recording search, the AcuSense alertStream (multipart)
  dahua_api    Dahua CGI: device, storage, record mode, camera state,
               the eventManager attach stream (SMD / IVS events)
  health_probe one report per DVR for /api/v1/shop/gateway/dvr-health
  multipart    the incremental multipart parser both event streams use

Rules: the DVR password is typed ONCE on the box and kept encrypted there
(shopbox.secure_store); it is never sent to the server, never logged.
No face recognition, no video upload from here.
"""
from . import dahua_api, discovery, health_probe, isapi, multipart  # noqa: F401
