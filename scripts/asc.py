#!/usr/bin/env python3
"""App Store Connect API steps for shipping Oscuru to TestFlight from CI.

    asc.py prepare WORK_DIR CERT_SERIAL   bundle IDs, app record, profiles and next build number
    asc.py testers APP_ID                 an internal TestFlight group that gets every build
    asc.py share BUILD [WHAT_TO_TEST]     that build, once Apple has processed it, to the invited testers
    asc.py crashes OUT_DIR                the crash reports testers sent from TestFlight, with their logs

Reads ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file). Prints no secrets.
`share` also reads OSCURU_PRIVACY_URL (the privacy policy's address, once there is one),
OSCURU_TESTER_LIMIT (how many people the invitation link lets in, 20 unless set) and
OSCURU_PROCESSING_MINUTES (how long to wait for Apple to process the build, 60 unless set).
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
# The extensions the app carries, each signed with its own App Store profile: (key for asc.env,
# bundle ID, name in the developer portal). They are optional: until both are registered and have
# a profile, the app is built without them (scripts/testflight.sh).
EXTENSIONS = [
    ("_CAPTURE", BUNDLE_ID + ".capture", "Oscuru Lock Screen camera"),
    ("_CONTROLS", BUNDLE_ID + ".controls", "Oscuru controls"),
]
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


def reason(reply):
    """What App Store Connect said was wrong, for the log."""
    return "; ".join(e.get("detail") or e.get("title", "") for e in reply.get("errors", [])) or "no details"


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

    # 1. The bundle IDs. Registering needs an Admin key; otherwise the owner registers them by hand.
    #    The app's is waited for; an extension's is skipped, and the app is built without it.
    def register(identifier, name, required):
        def find_bundle():
            reply = ok(*call("GET", "/v1/bundleIds", query={"filter[identifier]": identifier, "limit": 200}), "list bundle IDs")
            matches = [b for b in reply["data"] if b["attributes"]["identifier"] == identifier]
            return matches[0]["id"] if matches else None

        bundle = find_bundle()
        if bundle:
            print(f"Bundle ID {identifier} is registered.")
            return bundle
        status, reply = call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {"identifier": identifier, "name": name, "platform": "IOS"}}})
        if status < 300:
            notice(f"Registered the bundle ID {identifier}.")
            return reply["data"]["id"]
        print(f"::warning::Could not register {identifier} (HTTP {status}): {reason(reply)}", flush=True)
        if not required:
            return None
        bundle = waiting(
            find_bundle,
            f"the bundle ID {identifier}",
            f"Register it once: developer.apple.com/account → Certificates, IDs & Profiles → Identifiers → + → App IDs → App → "
            f"description {name}, explicit bundle ID {identifier} → Continue → Register.",
        )
        print(f"Bundle ID {identifier} is registered.")
        return bundle

    bundles = {"": (BUNDLE_ID, APP_NAME, register(BUNDLE_ID, APP_NAME, True))}
    for key, identifier, name in EXTENSIONS:
        bundle = register(identifier, name, False)
        if bundle:
            bundles[key] = (identifier, name, bundle)

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

    # 4. An App Store provisioning profile for each bundle ID and that certificate, whatever its name.
    def provision(identifier, name, bundle, required):
        def find_profile():
            reply = ok(
                *call("GET", "/v1/profiles", query={"filter[profileType]": "IOS_APP_STORE", "filter[profileState]": "ACTIVE", "include": "certificates,bundleId", "limit": 200}),
                "list profiles",
            )
            for item in reply["data"]:
                relationships = item.get("relationships", {})
                certificates = [c["id"] for c in relationships.get("certificates", {}).get("data", [])]
                bundle_data = relationships.get("bundleId", {}).get("data") or {}
                if certificate in certificates and bundle_data.get("id") == bundle:
                    status, full = call("GET", f"/v1/profiles/{item['id']}")
                    return ok(status, full, "read the profile")["data"]
            return None

        profile = find_profile()
        if profile is None:
            status, reply = call(
                "POST",
                "/v1/profiles",
                {
                    "data": {
                        "type": "profiles",
                        "attributes": {"name": f"{name} App Store (CI)", "profileType": "IOS_APP_STORE"},
                        "relationships": {
                            "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                            "certificates": {"data": [{"type": "certificates", "id": certificate}]},
                        },
                    }
                },
            )
            if status < 300:
                profile = reply["data"]
                notice(f"Created the App Store provisioning profile for {identifier}.")
            else:
                print(f"::warning::Could not create the profile for {identifier} (HTTP {status}): {reason(reply)}", flush=True)
                if not required:
                    return None
                profile = waiting(
                    find_profile,
                    f"the provisioning profile for {identifier}",
                    f"Create it once: developer.apple.com/account → Certificates, IDs & Profiles → Profiles → + → App Store Connect → Continue → "
                    f"App ID {name} ({identifier}) → Continue → the Apple Distribution certificate (the one Putia uses) → Continue → "
                    f"name {name} App Store → Generate. No need to download it.",
                )
        print(f"Provisioning profile for {identifier}: {profile['attributes']['name']}.")
        return profile

    profiles = {}
    for key, (identifier, name, bundle) in bundles.items():
        profile = provision(identifier, name, bundle, key == "")
        if profile is None:
            continue
        profiles[key] = profile["attributes"]["uuid"]
        filename = "profile" + key.lower().replace("_", "-") + ".mobileprovision"
        with open(os.path.join(work, filename), "wb") as handle:
            handle.write(base64.b64decode(profile["attributes"]["profileContent"]))

    # 5. The next build number: one more than any build uploaded so far, and no lower than
    # BUILD_NUMBER_FLOOR (the workflow's run number). A build Apple is still processing is not
    # listed yet, so two uploads a few minutes apart would otherwise both take the same number;
    # run numbers only go up.
    reply = ok(*call("GET", "/v1/builds", query={"filter[app]": app, "sort": "-uploadedDate", "limit": 20, "fields[builds]": "version"}), "list builds")
    numbers = [int(b["attributes"]["version"]) for b in reply["data"] if b["attributes"]["version"].isdigit()]
    floor = os.environ.get("BUILD_NUMBER_FLOOR", "0")
    build = max(max(numbers + [0]) + 1, int(floor) if floor.isdigit() else 0)

    with open(os.path.join(work, "asc.env"), "w") as handle:
        handle.write(f"APP_ID={app}\nBUILD_NUMBER={build}\n")
        for key, uuid in profiles.items():
            handle.write(f"PROFILE_UUID{key}={uuid}\n")
        with_extensions = all(key in profiles for key, _, _ in EXTENSIONS)
        handle.write(f"EXTENSIONS={'yes' if with_extensions else 'no'}\n")
    if not with_extensions:
        missing = ", ".join(identifier for key, identifier, _ in EXTENSIONS if key not in profiles)
        print(
            f"::warning::Building without the camera extensions (Camera Control, Action button, Control Center), as {missing} "
            "cannot be signed yet. Register each once: developer.apple.com/account → Certificates, IDs & Profiles → Identifiers → + → "
            "App IDs → App → explicit bundle ID. Then make an App Store profile for each with the Apple Distribution certificate Putia "
            "uses (Profiles → + → App Store Connect). The next build includes them.",
            flush=True,
        )
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


# The invited testers: people outside the team, who join with the group's link.
GROUP_NAME = "Friends"
BETA_DESCRIPTION = """Oscuru is a RAW camera and photo editor you talk to. Take RAW photos (one frame, or several the camera merges), or open RAW photos you already have, and tell the assistant what you want: it edits the photo with a photographer's tools and shows you each step. Nothing is generated: every pixel comes from the light the camera recorded.

You need your own OpenRouter account (openrouter.ai): connect it in Oscuru's Settings, and what the assistant does is paid from your OpenRouter credit. Oscuru has no server and no account of its own; your photos stay on your phone, and only the pictures the assistant looks at go to OpenRouter and the model you chose.

What to try: shoot or import a RAW photo, ask for a look ("moody film", "make the sky pop"), ask for changes, save a style and apply it to other photos. With Frames on in Settings, the camera takes several frames: ask the assistant for less noise, more detail, a long exposure or a focus stack."""


def app_id():
    reply = ok(*call("GET", "/v1/apps", query={"filter[bundleId]": BUNDLE_ID}), "look up the app")
    apps = [a for a in reply["data"] if a["attributes"]["bundleId"] == BUNDLE_ID]
    if not apps:
        sys.exit("No App Store Connect app for " + BUNDLE_ID)
    return apps[0]["id"]


def share(build_number, what_to_test=None):
    """Gives a build to the invited testers: once Apple has processed it, it joins the external
    group (made the first time, with an invitation link that lets in OSCURU_TESTER_LIMIT people)
    and goes to Apple's beta review, which external testers need. What only the owner can give
    (their contact details and an OpenRouter key for the reviewer) is left to them in App Store
    Connect: this only says what is still missing."""
    app = app_id()
    limit = int(os.environ.get("OSCURU_TESTER_LIMIT") or 20)
    missing = []

    # What testers read about the beta, and where its privacy policy is. The feedback email is the owner's to give.
    privacy = (os.environ.get("OSCURU_PRIVACY_URL") or "").strip()
    reply = ok(*call("GET", f"/v1/apps/{app}/betaAppLocalizations"), "read the beta's description")
    localizations = reply.get("data", [])
    english = next((l for l in localizations if l["attributes"].get("locale", "").startswith("en")), localizations[0] if localizations else None)
    wanted = {"description": BETA_DESCRIPTION}
    if privacy:
        wanted["privacyPolicyUrl"] = privacy
    if english:
        changed = {k: v for k, v in wanted.items() if english["attributes"].get(k) != v}
        if changed:
            ok(*call("PATCH", f"/v1/betaAppLocalizations/{english['id']}", {"data": {"type": "betaAppLocalizations", "id": english["id"], "attributes": changed}}), "write the beta's description")
        attributes = {**english["attributes"], **wanted}
    else:
        body = {"data": {"type": "betaAppLocalizations", "attributes": {"locale": "en-US", **wanted}, "relationships": {"app": {"data": {"type": "apps", "id": app}}}}}
        ok(*call("POST", "/v1/betaAppLocalizations", body), "write the beta's description")
        attributes = wanted
    if not attributes.get("feedbackEmail"):
        missing.append("a feedback email (TestFlight → Test Information)")
    if not attributes.get("privacyPolicyUrl"):
        print("::warning::The beta has no privacy policy URL yet (docs/privacy.md, once it has an address: the OSCURU_PRIVACY_URL variable).")

    # What Apple's reviewer needs: the owner's contact details, and a way to use the assistant.
    status, reply = call("GET", f"/v1/apps/{app}/betaAppReviewDetail")
    review = reply.get("data", {}).get("attributes", {}) if status < 300 else {}
    if not all(review.get(k) for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")):
        missing.append("your name, phone and email for the reviewer (TestFlight → Test Information → Beta App Review Information)")
    if not review.get("notes"):
        missing.append("review notes with an OpenRouter key for the reviewer (same place: Settings → Connect → paste the key)")

    # The group, with its invitation link.
    reply = ok(*call("GET", f"/v1/apps/{app}/betaGroups", query={"limit": 50}), "list TestFlight groups")
    group = next((g for g in reply["data"] if not g["attributes"].get("isInternalGroup") and g["attributes"].get("name") == GROUP_NAME), None)
    if not group:
        attributes = {"name": GROUP_NAME, "isInternalGroup": False, "feedbackEnabled": True}
        body = {"data": {"type": "betaGroups", "attributes": attributes, "relationships": {"app": {"data": {"type": "apps", "id": app}}}}}
        group = ok(*call("POST", "/v1/betaGroups", body), "create the invited testers' group")["data"]
        notice(f"Created the TestFlight group “{GROUP_NAME}” for invited testers.")

    # The build, once Apple has processed it.
    deadline = time.time() + 60 * int(os.environ.get("OSCURU_PROCESSING_MINUTES") or 60)
    build = None
    while True:
        status, reply = call("GET", "/v1/builds", query={"filter[app]": app, "filter[version]": str(build_number), "limit": 5})
        found = reply.get("data", []) if status < 300 else []
        if found and found[0]["attributes"].get("processingState") == "VALID":
            build = found[0]
            break
        if found and found[0]["attributes"].get("processingState") in ("FAILED", "INVALID"):
            sys.exit(f"Apple could not process build {build_number}.")
        if time.time() > deadline:
            sys.exit(f"Build {build_number} was not processed in time; the next build will be shared instead.")
        time.sleep(30)

    if what_to_test:
        reply = ok(*call("GET", f"/v1/builds/{build['id']}/betaBuildLocalizations"), "read what to test")
        localizations = reply.get("data", [])
        if localizations:
            body = {"data": {"type": "betaBuildLocalizations", "id": localizations[0]["id"], "attributes": {"whatsNew": what_to_test}}}
            call("PATCH", f"/v1/betaBuildLocalizations/{localizations[0]['id']}", body)
        else:
            body = {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": "en-US", "whatsNew": what_to_test}, "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}}
            call("POST", "/v1/betaBuildLocalizations", body)

    ok(*call("POST", f"/v1/betaGroups/{group['id']}/relationships/builds", {"data": [{"type": "builds", "id": build["id"]}]}), "add the build to the invited testers' group")
    print(f"Build {build_number} is in the group “{GROUP_NAME}”.")

    # The invitation link, letting in at most `limit` people.
    link = {"publicLinkEnabled": True, "publicLinkLimitEnabled": True, "publicLinkLimit": limit}
    if any(group["attributes"].get(k) != v for k, v in link.items()):
        status, reply = call("PATCH", f"/v1/betaGroups/{group['id']}", {"data": {"type": "betaGroups", "id": group["id"], "attributes": link}})
        if status < 300:
            group = reply["data"]
        else:
            print(f"::warning::Could not turn on the invitation link: {reason(reply)}")

    if missing:
        notice("Build " + str(build_number) + " is not sent to Apple's beta review until App Store Connect has: " + "; ".join(missing) + ". The next build goes once they are there.")
        return
    status, reply = call("POST", "/v1/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
    if status < 300:
        print(f"Build {build_number} is sent to Apple's beta review.")
    else:
        print(f"::warning::Build {build_number} was not sent to beta review: {reason(reply)}")
    if group["attributes"].get("publicLink"):
        notice(f"Invited testers join with {group['attributes']['publicLink']} (at most {limit} people), once Apple has approved a build.")


def crashes(out):
    """Saves every crash report sent from TestFlight for this app: what Apple records with it (the
    build, device, system, how long the app had run) and the crash log itself. Leaves out who sent
    it. Reads only."""
    os.makedirs(out, exist_ok=True)
    reply = ok(*call("GET", "/v1/apps", query={"filter[bundleId]": BUNDLE_ID}), "look up the app")
    apps = [a for a in reply["data"] if a["attributes"]["bundleId"] == BUNDLE_ID]
    if not apps:
        sys.exit("No App Store Connect app for " + BUNDLE_ID)
    app = apps[0]["id"]
    submissions = []
    path, query = f"/v1/apps/{app}/betaFeedbackCrashSubmissions", {"limit": 200, "include": "build"}
    while path:
        status, reply = call("GET", path, query=query)
        if status >= 300 and query and "include" in query:
            # Not every version of the API takes "include" here.
            query = {"limit": 200}
            continue
        reply = ok(status, reply, "list the crash reports")
        submissions += reply.get("data", [])
        builds = {b["id"]: b["attributes"].get("version") for b in reply.get("included", []) if b.get("type") == "builds"}
        for submission in reply.get("data", []):
            build = submission.get("relationships", {}).get("build", {}).get("data") or {}
            submission["buildNumber"] = builds.get(build.get("id"))
        following = reply.get("links", {}).get("next")
        path, query = (following.replace(API, ""), None) if following else (None, None)
    print(f"{len(submissions)} crash reports.")
    summary = []
    for index, submission in enumerate(sorted(submissions, key=lambda s: s["attributes"].get("createdDate") or "", reverse=True)):
        attributes = {k: v for k, v in submission["attributes"].items() if k not in ("email", "testerEmail")}
        status, log = call("GET", f"/v1/betaFeedbackCrashSubmissions/{submission['id']}/crashLog")
        text = ""
        if status < 300:
            data = log.get("data", {}).get("attributes", {})
            # The log's text, under whichever attribute holds it.
            text = data.get("logText") or next((v for v in data.values() if isinstance(v, str) and len(v) > 200), "") or json.dumps(data, indent=2)
        else:
            text = f"(no crash log: HTTP {status}: {reason(log)})"
        name = f"{index + 1:02d}-build{submission.get('buildNumber') or 'unknown'}"
        with open(os.path.join(out, name + ".crash"), "w") as handle:
            handle.write(text)
        with open(os.path.join(out, name + ".json"), "w") as handle:
            json.dump({"id": submission["id"], "build": submission.get("buildNumber"), **attributes}, handle, indent=2)
        summary.append(f"{name}: {attributes.get('createdDate')} build {submission.get('buildNumber')} {attributes.get('deviceModel')} iOS {attributes.get('osVersion')}")
    with open(os.path.join(out, "summary.txt"), "w") as handle:
        handle.write("\n".join(summary) + "\n")
    print("\n".join(summary))


if __name__ == "__main__":
    if sys.argv[1] == "prepare":
        prepare(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "testers":
        testers(sys.argv[2])
    elif sys.argv[1] == "share":
        text = None
        if len(sys.argv) > 3 and os.path.exists(sys.argv[3]):
            with open(sys.argv[3]) as handle:
                text = handle.read().strip()[:3900] or None
        share(sys.argv[2], text)
    elif sys.argv[1] == "crashes":
        crashes(sys.argv[2])
    else:
        sys.exit(__doc__)
