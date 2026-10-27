#!/usr/bin/env python3
"""Create/update a-user-of-python/metalcad (PRIVATE) and push the MetalCAD tree.
Blobs -> tree -> commit -> ref via the git-database API, tree-verified after."""
import base64, hashlib, json, os, sys, urllib.request, urllib.error
sys.path.insert(0, "/opt/hatch/skills/skill-creator/bin")
from dynamic_credentials import add_surrogate_to_request, read_json_response, ensure_allowed_url

API = "https://api.github.com"; ALLOWED = ["api.github.com"]
OWNER, REPO = "a-user-of-python", "cascade-ios"
ROOT = os.path.expanduser("~/workspace/cascade-port")
MESSAGE = sys.argv[1] if len(sys.argv) > 1 else "MetalCAD: kit + app + CI"

SKIP_DIRS = {".build", "__pycache__"}
SKIP_SUFFIX = (".pdf", ".webp", ".png", ".tar.gz")

def api(method, path, data=None):
    url = API + path
    ensure_allowed_url(url, ALLOWED)
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body: req.add_header("Content-Type", "application/json")
    add_surrogate_to_request(req, "custom.github", allowed_hosts=ALLOWED)
    try:
        return read_json_response(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        print(f"API FAIL {method} {path} -> HTTP {e.code}: {e.read().decode(errors='replace')[:300]}")
        raise

# 1. Create the repo (private). 422 = already exists -> fine.
try:
    r = api("POST", "/user/repos", {"name": REPO, "private": True,
        "description": "CascadePort - Open CASCADE (OCCT) iOS port: OCCT subset + thin C facade + SwiftUI demo. Open CascadePort.xcodeproj and Run on iPad."})
    print("repo created:", r.get("full_name"))
except urllib.error.HTTPError as e:
    print("create repo -> HTTP", e.code, "(continuing if it already exists)")

# 1b. An empty repo rejects git-database calls (409). Seed it with an
# initial commit via the Contents API if main doesn't exist yet.
try:
    api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/main")
    print("main ref exists")
except urllib.error.HTTPError:
    with open(os.path.join(ROOT, "README.md"), "rb") as f:
        readme_b64 = base64.b64encode(f.read()).decode()
    api("PUT", f"/repos/{OWNER}/{REPO}/contents/README.md",
        {"message": "Initial commit", "content": readme_b64, "branch": "main"})
    print("seeded initial commit via Contents API")

# 2. Collect files.
paths = []
for base in [ROOT]:
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and d != ".git"]
        for fn in filenames:
            # Asset-catalog payloads (e.g. the AppIcon PNG) must ship:
            # without the image, CI builds an icon set with no content
            # and the app silently gets no icon. Stray .png/.pdf/.webp
            # files elsewhere are still skipped.
            if fn.endswith(SKIP_SUFFIX) and ".xcassets" not in dirpath:
                continue
            if fn == ".DS_Store":
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, ROOT)
            if rel.startswith("images/") or rel in ("build_pdf.py",):
                continue
            paths.append((rel, full))
paths.sort()
print(f"{len(paths)} files to push")

# 3. Blobs.
tree_items = []
for rel, full in paths:
    with open(full, "rb") as f:
        content = f.read()
    blob = api("POST", f"/repos/{OWNER}/{REPO}/git/blobs",
               {"content": base64.b64encode(content).decode(), "encoding": "base64"})
    mode = "100755" if os.access(full, os.X_OK) and rel.endswith(".py") else "100644"
    tree_items.append({"path": rel, "mode": mode, "type": "blob", "sha": blob["sha"]})

# 4. Tree + commit.
tree = api("POST", f"/repos/{OWNER}/{REPO}/git/trees", {"tree": tree_items})
print("tree:", tree["sha"])
parents = []
try:
    ref = api("GET", f"/repos/{OWNER}/{REPO}/git/ref/heads/main")
    parents = [ref["object"]["sha"]]
    print("parent:", parents[0])
except urllib.error.HTTPError:
    print("no existing main ref - initial commit")
commit = api("POST", f"/repos/{OWNER}/{REPO}/git/commits",
             {"message": MESSAGE, "tree": tree["sha"], "parents": parents})
print("commit:", commit["sha"])

# 5. Ref.
if parents:
    api("PATCH", f"/repos/{OWNER}/{REPO}/git/refs/heads/main", {"sha": commit["sha"]})
else:
    api("POST", f"/repos/{OWNER}/{REPO}/git/refs", {"ref": "refs/heads/main", "sha": commit["sha"]})
print("ref updated")

# 6. Verify by tree.
head = api("GET", f"/repos/{OWNER}/{REPO}/git/commits/{commit['sha']}")
assert head["tree"]["sha"] == tree["sha"], "TREE MISMATCH"
print("VERIFIED: remote tree ==", tree["sha"])
