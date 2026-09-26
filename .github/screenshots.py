"""The pull request's Screenshots check (.github/workflows/screenshots.yml).

Pictures on the screenshots branch for the pull request's branch (put there
by ./screenshots.sh, or by .githooks/pre-push as the branch is pushed) go
into the body's Screenshots section, unless they are in it already. Without
any, the section needs a picture of its own or the words "Nothing on screen
changes."; otherwise the check fails. docs/pull-requests.md has the rules.
"""
import os
import re
import subprocess
import sys
import urllib.parse

env = os.environ
head, branch = env["HEAD_REPO"], env["BRANCH"]
body = (env.get("BODY") or "").replace("\r\n", "\n")
raw = f"https://raw.githubusercontent.com/{head}/screenshots/{branch}/"


def fail(message):
    print(f"::error::{message}")
    sys.exit(1)


def uploaded(name):
    path = urllib.parse.quote(f"{branch}/{name}")
    found = subprocess.run(["gh", "api", f"repos/{head}/contents/{path}?ref=screenshots", "--silent"],
                           capture_output=True)
    return found.returncode == 0


section = re.search(r"^## Screenshots[ \t]*\n(.*?)(?=^## |\Z)", body, re.S | re.M)
if not section:
    fail("The body has no ## Screenshots section (.github/pull_request_template.md).")
said = re.sub(r"<!--.*?-->", "", section.group(1), flags=re.S)

shots = [name for name in ("before.png", "after.png") if uploaded(name)]
if shots and not all(raw + name in said for name in shots):
    if len(shots) == 2:
        pictures = f"| Before | After |\n| --- | --- |\n| ![before]({raw}before.png) | ![after]({raw}after.png) |"
    else:
        pictures = f"![{shots[0].removesuffix('.png')}]({raw}{shots[0]})"
    body = body[:section.start(1)] + "\n" + pictures + "\n\n" + body[section.end(1):]
    subprocess.run(["gh", "pr", "edit", env["PR"], "--repo", env["BASE_REPO"], "--body-file", "-"],
                   input=body, text=True, check=True)
    print(f"Put {' and '.join(shots)} in the body.")
elif shots or re.search(r"!\[[^\]]*\]\(|<img ", said):
    print("The screenshots are in.")
elif "Nothing on screen changes." in said:
    print("Nothing on screen changes.")
else:
    fail("No screenshots. Take build/after.png in the test VM (and build/before.png for a fix or a change) and "
         "push again, or run ./screenshots.sh. A change with nothing on screen says \"Nothing on screen changes.\" "
         "See docs/pull-requests.md#screenshots.")
