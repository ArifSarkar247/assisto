"""Local mock of Google's OAuth2 token endpoint + FCM HTTP v1 (e2e harness).

    python mock_fcm.py --port 18790 --sa sa.json --log fcm_calls.jsonl
    python mock_fcm.py --make-sa sa.json --port 18790   # write a throw-away SA

The backend's REAL push path (core/push.py: RS256 JWT -> token exchange ->
messages:send) runs against this server (settings_e2e points FCM_TOKEN_URI /
FCM_SEND_URL here). The JWT signature is VERIFIED with the generated service
account's public key, so a broken signer fails the harness. Every accepted
message is appended to --log as one JSON line; GET /calls returns them all.
"""
import argparse
import base64
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs


def _b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def make_sa(path, port):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM,
                            serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    sa = {"type": "service_account", "project_id": "assisto-e2e",
          "private_key_id": "e2e", "private_key": pem,
          "client_email": "e2e@assisto-e2e.iam.gserviceaccount.com",
          "token_uri": "http://127.0.0.1:%d/token" % port}
    with open(path, "w") as f:
        json.dump(sa, f)


def verify_jwt(jwt, sa):
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    h, c, s = jwt.split(".")
    key = serialization.load_pem_private_key(sa["private_key"].encode(), None)
    key.public_key().verify(_b64d(s), ("%s.%s" % (h, c)).encode(),
                            padding.PKCS1v15(), hashes.SHA256())
    claims = json.loads(_b64d(c))
    assert claims["iss"] == sa["client_email"], "iss"
    assert "firebase.messaging" in claims["scope"], "scope"
    return claims


class State:
    lock = threading.Lock()
    calls = []
    sa = None
    log = None
    token = "e2e-access-token"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/calls":
            with State.lock:
                return self._send(200, {"calls": list(State.calls)})
        if self.path == "/health":
            return self._send(200, {"ok": True})
        self._send(404, {})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        if self.path == "/token":
            q = parse_qs(body.decode())
            try:
                verify_jwt(q["assertion"][0], State.sa)
            except Exception as e:
                return self._send(400, {"error": "invalid_grant",
                                        "error_description": str(e)[:100]})
            return self._send(200, {"access_token": State.token,
                                    "expires_in": 3600, "token_type": "Bearer"})
        if self.path.startswith("/v1/projects/") and self.path.endswith(":send"):
            if self.headers.get("Authorization") != "Bearer " + State.token:
                return self._send(401, {"error": {"status": "UNAUTHENTICATED"}})
            msg = json.loads(body.decode())["message"]
            with State.lock:
                State.calls.append(msg)
                n = len(State.calls)
                if State.log:
                    with open(State.log, "a") as f:
                        f.write(json.dumps(msg, ensure_ascii=False) + "\n")
            return self._send(200, {"name": "projects/assisto-e2e/messages/%d" % n})
        self._send(404, {})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18790)
    ap.add_argument("--sa", default="")
    ap.add_argument("--log", default="")
    ap.add_argument("--make-sa", default="")
    a = ap.parse_args()
    if a.make_sa:
        make_sa(a.make_sa, a.port)
        return
    with open(a.sa) as f:
        State.sa = json.load(f)
    State.log = a.log or None
    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
