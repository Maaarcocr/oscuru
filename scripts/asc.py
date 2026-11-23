#!/usr/bin/env python3
"""App Store Connect API steps for shipping Oscuru to TestFlight from CI.

    asc.py prepare WORK_DIR CERT_SERIAL   bundle ID, app record, profile and next build number
    asc.py testers APP_ID                 an internal TestFlight group that gets every build

Reads ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file). Prints no secrets.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

BUNDLE_ID = "com.rudilosso.oscuru"
APP_NAME = "Oscuru"
PROFILE_NAME = "Oscuru App Store (CI)"
API = "https://api.appstoreconnect.apple.com"


def token():
    with open(os.environ["ASC_KEY_PATH"]) as handle:
        key = handle.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method, path, body=None, query=None):
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            text = response.read()
            return response.status, (json.loads(text) if text else {})
    except urllib.error.HTTPError as error:
        text = error.read()
        try:
            return error.code, json.loads(text)
        except ValueError:
            return error.code, {"errors": [{"detail": text.decode(errors="replace")[:300]}]}


def ok(status, reply, what):
    if status >= 300:
        details = "; ".join(e.get("detail") or e.get("title", "") for e in reply.get("errors", []))
        sys.exit(f"App Store Connect refused to {what} (HTTP {status}): {details}")
    return reply


def notice(text):
    print(f"::notice::{text}", flush=True)


# How long to wait for the person to do what only they can do (accept Apple's agreement, create the
# app record) before giving up. Set by the workflow; 0 fails at once.
WAIT_SECONDS = int(os.environ.get("ASC_WAIT_MINUTES", "0")) * 60


def waiting(check, what, instructions):
    """Calls `check` until it returns something, telling the person once what to do meanwhile."""
    deadline = time.time() + WAIT_SECONDS
    told = False
    while True:
        result = check()
        if result is not None:
            return result
        if time.time() >= deadline:
            print(f"::error::{instructions}", flush=True)
            sys.exit(3)
        if not told:
            print(f"::warning::Waiting for {what}. {instructions}", flush=True)
            told = True
        time.sleep(30)


def prepare(work, serial):
    # 0. Apple refuses everything until the Account Holder accepts its latest agreement.
    def agreement():
        status, reply = call("GET", "/v1/bundleIds", query={"filter[identifier]": BUNDLE_ID, "limit": 200})
        if status == 403 and "agreement" in json.dumps(reply).lower():
            return None
        return ok(status, reply, "list bundle IDs")

    reply = waiting(
        agreement,
        "Apple's agreement",
        "Apple needs the Account Holder to accept its updated Developer Program agreement: on your iPhone open "
        "developer.apple.com/account in Safari, sign in, and tap Review and Agree on the banner.",
    )

    # 1. The bundle ID.
    matches = [b for b in reply["data"] if b["attributes"]["identifier"] == BUNDLE_ID]
    if matches:
        bundle = matches[0]["id"]
        print(f"Bundle ID {BUNDLE_ID} is registered.")
    else:
        def register():
            status, reply = call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {"identifier": BUNDLE_ID, "name": APP_NAME, "platform": "IOS"}}})
            # Apple can take a while to apply an accepted agreement to every part of the account.
            if status == 403 and "agreement" in json.dumps(reply).lower():
                return None
            return ok(status, reply, "register the bundle ID")

        reply = waiting(
            register,
            "Apple to accept the agreement for registering identifiers",
            "Apple still says an agreement is pending. Check appstoreconnect.apple.com → Business (Agreements) and "
            "developer.apple.com/account for anything left to accept.",
        )
        bundle = reply["data"]["id"]
        notice(f"Registered the bundle ID {BUNDLE_ID}.")

    # 2. The app record. Apple's API cannot create one: a person does, once.
    def app_record():
        reply = ok(*call("GET", "/v1/apps", query={"filter[bundleId]": BUNDLE_ID}), "look up the app")
        apps = [a for a in reply["data"] if a["attributes"]["bundleId"] == BUNDLE_ID]
        return apps[0]["id"] if apps else None

    app = waiting(
        app_record,
        "the App Store Connect app",
        f"Create Oscuru once in App Store Connect (appstoreconnect.apple.com in Safari): Apps → + → New App → iOS, "
        f"name {APP_NAME}, bundle ID {BUNDLE_ID}, SKU oscuru, full access. The build carries on by itself once it exists.",
    )
    print(f"App record found ({app}).")

    # 3. The distribution certificate from the owner's .p12, found by serial number.
    wanted = serial.upper().lstrip("0")
    certificate = None
    for kind in ("DISTRIBUTION", "IOS_DISTRIBUTION"):
        reply = ok(*call("GET", "/v1/certificates", query={"filter[certificateType]": kind, "limit": 200}), "list certificates")
        for item in reply["data"]:
            if item["attributes"].get("serialNumber", "").upper().lstrip("0") == wanted:
                certificate = item["id"]
    if not certificate:
        sys.exit("The distribution certificate in the .p12 is not on this team's App Store Connect account.")

    # 4. An App Store provisioning profile for the bundle ID and that certificate.
    reply = ok(
        *call("GET", "/v1/profiles", query={"filter[name]": PROFILE_NAME, "filter[profileType]": "IOS_APP_STORE", "include": "certificates,bundleId", "limit": 50}),
        "list profiles",
    )
    profile = None
    for item in reply["data"]:
        certificates = [c["id"] for c in item["relationships"]["certificates"]["data"]] if "data" in item["relationships"].get("certificates", {}) else []
        if item["attributes"]["profileState"] == "ACTIVE" and certificate in certificates and item["relationships"]["bundleId"]["data"]["id"] == bundle:
            profile = item
            break
    if profile is None:
        for item in reply["data"]:
            call("DELETE", f"/v1/profiles/{item['id']}")
        reply = ok(
            *call(
                "POST",
                "/v1/profiles",
                {
                    "data": {
                        "type": "profiles",
                        "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_STORE"},
                        "relationships": {
                            "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                            "certificates": {"data": [{"type": "certificates", "id": certificate}]},
                        },
                    }
                },
            ),
            "create the provisioning profile",
        )
        profile = reply["data"]
        notice("Created the App Store provisioning profile.")
    with open(os.path.join(work, "profile.mobileprovision"), "wb") as handle:
        handle.write(base64.b64decode(profile["attributes"]["profileContent"]))

    # 5. The next build number: one more than any build uploaded so far.
    reply = ok(*call("GET", "/v1/builds", query={"filter[app]": app, "sort": "-uploadedDate", "limit": 20, "fields[builds]": "version"}), "list builds")
    numbers = [int(b["attributes"]["version"]) for b in reply["data"] if b["attributes"]["version"].isdigit()]
    build = max(numbers + [0]) + 1

    with open(os.path.join(work, "asc.env"), "w") as handle:
        handle.write(f"APP_ID={app}\nPROFILE_UUID={profile['attributes']['uuid']}\nBUILD_NUMBER={build}\n")
    print(f"Build number {build}.")


def testers(app):
    """Makes sure the team's members get every build in TestFlight, without anyone tapping anything."""
    reply = ok(*call("GET", f"/v1/apps/{app}/betaGroups", query={"limit": 50}), "list TestFlight groups")
    groups = [g for g in reply["data"] if g["attributes"].get("isInternalGroup")]
    if groups:
        group = groups[0]["id"]
        if not groups[0]["attributes"].get("hasAccessToAllBuilds"):
            call("PATCH", f"/v1/betaGroups/{group}", {"data": {"type": "betaGroups", "id": group, "attributes": {"hasAccessToAllBuilds": True}}})
    else:
        status, reply = call(
            "POST",
            "/v1/betaGroups",
            {
                "data": {
                    "type": "betaGroups",
                    "attributes": {"name": "Me", "isInternalGroup": True, "hasAccessToAllBuilds": True},
                    "relationships": {"app": {"data": {"type": "apps", "id": app}}},
                }
            },
        )
        if status >= 300:
            print("::warning::Could not create an internal TestFlight group; add yourself as an internal tester in App Store Connect → Oscuru → TestFlight.")
            return
        group = reply["data"]["id"]
        notice("Created the internal TestFlight group “Me”, with access to every build.")
    status, reply = call("GET", "/v1/users", query={"limit": 50})
    if status >= 300:
        print("::warning::This API key cannot list the team's users; add yourself to the internal TestFlight group in App Store Connect.")
        return
    for user in reply["data"]:
        attributes = user["attributes"]
        status, _ = call(
            "POST",
            "/v1/betaTesters",
            {
                "data": {
                    "type": "betaTesters",
                    "attributes": {"email": attributes["username"], "firstName": attributes.get("firstName") or "", "lastName": attributes.get("lastName") or ""},
                    "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group}]}},
                }
            },
        )
        print(f"Internal tester {'added' if status < 300 else 'already present or not added'} ({status}).")


if __name__ == "__main__":
    if sys.argv[1] == "prepare":
        prepare(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "testers":
        testers(sys.argv[2])
    else:
        sys.exit(__doc__)
