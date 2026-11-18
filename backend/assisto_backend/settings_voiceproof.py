"""voice-proof: settings_ci + a THROW-AWAY integrations key generated inside
the CI job (VP_FERNET_KEY), so the in-runner server can hold the
"voice_transcribe" integration that points at the runner's local Whisper
(voice-emu.yml). settings_ci scrubs the real key name; this one never
exists outside that job."""
import os

from .settings_ci import *  # noqa: F401,F403

if os.getenv("VP_FERNET_KEY"):
    os.environ["INTEGRATIONS_FERNET_KEY"] = os.environ["VP_FERNET_KEY"]
