#!/usr/bin/env python3
"""staging (owner order 17 Nov): upload the "Assisto Test" APK to Firebase App
Distribution (free; NOT Google Play) and send it to the tester group "owner".

Firebase App Distribution REST API v1 with a service-account key (role
"Firebase App Distribution Admin"). Everything comes from the environment:

  APPDIST_SA_JSON   service-account key JSON (GitHub secret, never printed)
  APPDIST_APP_ID    Firebase app id of com.assisto.assisto.staging
                    ("1:<project number>:android:<hash>")
  APPDIST_TESTERS   comma-separated tester e-mails (added to the group)
  APPDIST_GROUP     tester group alias (default "owner")

usage: appdist_upload.py <apk> <release-notes.txt>
Exit 0 = distributed. Any API error prints the HTTP status + Google's message
(never the key) and exits 1.
"""
import json
import os
import sys
import time

import requests
from google.auth.transport.requests import Request
from google.oauth2 import service_account

API = "https://firebaseappdistribution.googleapis.com"
SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]


def die(msg, r=None):
    if r is not None:
        try:
            detail = r.json().get("error", {}).get("message", "")
        except Exception:
            detail = r.text[:300]
        msg = "%s (HTTP %s: %s)" % (msg, r.status_code, detail)
    print("::error::" + msg)
    sys.exit(1)


def main(apk, notes_path):
    info = json.loads(os.environ["APPDIST_SA_JSON"])
    app_id = os.environ["APPDIST_APP_ID"].strip()
    parts = app_id.split(":")
    if len(parts) != 4 or parts[2] != "android" or not parts[1].isdigit():
        die("APPDIST_APP_ID is not a Firebase Android app id (1:<number>:android:<hash>)")
    project = parts[1]
    group = os.environ.get("APPDIST_GROUP", "owner").strip() or "owner"
    testers = [e.strip() for e in os.environ.get("APPDIST_TESTERS", "").split(",") if e.strip()]

    creds = service_account.Credentials.from_service_account_info(info, scopes=SCOPES)
    creds.refresh(Request())
    s = requests.Session()
    s.headers["Authorization"] = "Bearer " + creds.token

    # 1) tester group "owner" (409 = already there) + its testers
    r = s.post("%s/v1/projects/%s/groups" % (API, project), params={"groupId": group},
               json={"displayName": "Owner"}, timeout=60)
    if r.status_code not in (200, 409):
        die("could not create tester group '%s'" % group, r)
    if testers:
        r = s.post("%s/v1/projects/%s/groups/%s:batchJoin" % (API, project, group),
                   json={"emails": testers, "createMissingTesters": True}, timeout=60)
        if r.status_code != 200:
            die("could not add testers to '%s'" % group, r)
    print("group '%s' ready with %d tester(s)" % (group, len(testers)))

    # 2) upload the APK (long-running operation)
    with open(apk, "rb") as f:
        r = s.post("%s/upload/v1/projects/%s/apps/%s/releases:upload" % (API, project, app_id),
                   headers={"X-Goog-Upload-Protocol": "raw",
                            "X-Goog-Upload-File-Name": os.path.basename(apk),
                            "Content-Type": "application/octet-stream"},
                   data=f, timeout=900)
    if r.status_code != 200:
        die("APK upload failed", r)
    op = r.json()["name"]
    release = None
    for _ in range(90):                       # <= ~7.5 min
        r = s.get("%s/v1/%s" % (API, op), timeout=60)
        if r.status_code != 200:
            die("upload status check failed", r)
        j = r.json()
        if j.get("done"):
            if "error" in j:
                die("App Distribution rejected the APK: %s" % j["error"].get("message", ""))
            release = j["response"]["release"]
            print("upload result:", j["response"].get("result", ""))
            break
        time.sleep(5)
    if not release:
        die("APK processing did not finish in time")
    name = release["name"]
    print("release:", release.get("displayVersion", ""), "(%s)" % release.get("buildVersion", ""))

    # 3) release notes (App Distribution limit 16 000 chars)
    notes = open(notes_path, encoding="utf-8").read()[:15900]
    r = s.patch("%s/v1/%s" % (API, name), params={"updateMask": "release_notes.text"},
                json={"releaseNotes": {"text": notes}}, timeout=60)
    if r.status_code != 200:
        die("could not set release notes", r)

    # 4) distribute to the group (+ the testers directly, belt and braces)
    r = s.post("%s/v1/%s:distribute" % (API, name),
               json={"groupAliases": [group], "testerEmails": testers}, timeout=60)
    if r.status_code != 200:
        die("distribute failed", r)
    print("DISTRIBUTED to group '%s' — testers get an e-mail / App Tester update" % group)
    link = release.get("testingUri") or release.get("firebaseConsoleUri") or ""
    out = os.environ.get("GITHUB_STEP_SUMMARY")
    if out:
        with open(out, "a") as f:
            f.write("### Assisto Test distributed\n\nrelease %s (%s) -> group `%s`\n\n%s\n"
                    % (release.get("displayVersion", ""), release.get("buildVersion", ""), group,
                       ("tester link: " + release["testingUri"]) if release.get("testingUri") else ""))
    if link:
        print("link:", link)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
