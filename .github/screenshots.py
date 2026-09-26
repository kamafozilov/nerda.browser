"""The pull request's Screenshots check (.github/workflows/screenshots.yml).

Every picture on refs/screenshots/<the pull request's branch> (put there by
./screenshots.sh, or by .githooks/pre-push as the branch is pushed) goes into
the body's Screenshots section, in the order of their names, unless they are
in it already; pictures sent again have a new address, and replace the old
ones. A before and an after of the same name go side by side. Without any,
the section needs a picture of its own or the words "Nothing on screen
changes."; otherwise the check fails. docs/pull-requests.md has the rules.
"""
import os
import re
import subprocess
import sys
import urllib.parse


def caption(name):
    """`2-extensions-menu` as "Extensions menu"; a bare before/after, none."""
    words = re.sub(r"^\d+[-_ ]*", "", name).replace("-", " ").replace("_", " ").strip()
    return words[:1].upper() + words[1:]


def render(names, raw):
    """The section's pictures: each thing under its caption, alone, or its
    before and after side by side."""
    shows = {}
    for file in sorted(names, key=lambda n: [int(p) if p.isdigit() else p for p in re.split(r"(\d+)", n)]):
        stem = file.removesuffix(".png")
        side = None
        for kind in ("before", "after"):
            if stem == kind or stem.endswith("." + kind):
                side, stem = kind, stem.removesuffix(kind).removesuffix(".")
        shows.setdefault(stem, {})[side] = file
    parts = []
    for stem, files in shows.items():
        title = caption(stem)
        lines = [f"**{title}**", ""] if title else []
        if "before" in files and "after" in files:
            lines += ["| Before | After |", "| --- | --- |",
                      f"| ![before]({raw}{files['before']}) | ![after]({raw}{files['after']}) |"]
        else:
            lines += [f"![{title or file.removesuffix('.png')}]({raw}{file})" for file in files.values()]
        parts.append("\n".join(lines))
    return "\n\n".join(parts)


def main():
    env = os.environ
    head, branch = env["HEAD_REPO"], env["BRANCH"]
    body = (env.get("BODY") or "").replace("\r\n", "\n")

    def fail(message):
        print(f"::error::{message}")
        sys.exit(1)

    ref = subprocess.run(["gh", "api", f"repos/{head}/git/ref/screenshots/{urllib.parse.quote(branch)}",
                          "--jq", ".object.sha"], capture_output=True, text=True)
    commit = ref.stdout.strip() if ref.returncode == 0 else None
    raw = f"https://raw.githubusercontent.com/{head}/{commit}/"
    names = []
    if commit:
        tree = subprocess.run(["gh", "api", f"repos/{head}/git/trees/{commit}", "--jq", ".tree[].path"],
                              capture_output=True, text=True)
        names = [n for n in tree.stdout.split() if n.endswith(".png")] if tree.returncode == 0 else []

    section = re.search(r"^## Screenshots[ \t]*\n(.*?)(?=^## |\Z)", body, re.S | re.M)
    if not section:
        fail("The body has no ## Screenshots section (.github/pull_request_template.md).")
    said = re.sub(r"<!--.*?-->", "", section.group(1), flags=re.S)

    if names and not all(raw + name in said for name in names):
        body = body[:section.start(1)] + "\n" + render(names, raw) + "\n\n" + body[section.end(1):]
        subprocess.run(["gh", "pr", "edit", env["PR"], "--repo", env["BASE_REPO"], "--body-file", "-"],
                       input=body, text=True, check=True)
        print(f"Put {', '.join(names)} in the body.")
    elif names or re.search(r"!\[[^\]]*\]\(|<img ", said):
        print("The screenshots are in.")
    elif "Nothing on screen changes." in said:
        print("Nothing on screen changes.")
    else:
        print("No screenshots; they are optional (docs/pull-requests.md#screenshots).")


if __name__ == "__main__":
    main()
