#!/usr/bin/env python3
"""Print a fingerprint of the resolved app list, for build cache busting.

A secret-mounted `RUN` is not part of the build cache key, so without this a
changed app list - or a moved app *branch* - would reuse a cached `bench init`
and silently ship a stale image.

Fingerprint inputs:
  * SOLRISE_APP_REV (optional manual override)
  * the resolved apps.json content
  * the remote commit SHA of every git app (best effort)

`host.containers.internal` is a container-only name, so it is also tried as
127.0.0.1 for the local git-daemon case.
"""

import hashlib
import json
import os
import subprocess
import sys


def remote_sha(url, branch):
    for candidate in (url, url.replace("host.containers.internal", "127.0.0.1")):
        try:
            out = subprocess.run(
                ["git", "ls-remote", candidate, branch],
                capture_output=True, text=True, timeout=30,
            )
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.split()[0]
        except Exception:
            continue
    return None


def main(path):
    apps = json.load(open(path))
    parts = [os.environ.get("SOLRISE_APP_REV", ""), json.dumps(apps, sort_keys=True)]
    for app in apps:
        url, branch = app.get("url"), app.get("branch")
        if not url or not branch:
            continue
        sha = remote_sha(url, branch)
        if sha:
            parts.append(sha)
    print(hashlib.sha256("|".join(parts).encode()).hexdigest())


if __name__ == "__main__":
    main(sys.argv[1])
