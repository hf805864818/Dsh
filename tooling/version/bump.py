#!/usr/bin/env python3
"""Bump the build number in app/pubspec.yaml, and nothing else.

Why a build number and not a pre-release tag: Flutter's `version:` is `x.y.z+build`.
`1.4.0b1` is not valid semver and `flutter build` rejects it, while `1.4.0-beta.1`
would change what CFBundleShortVersionString reports on the App Store side. Keeping
the base version (`1.4.0`, which comes from upstream) and advancing the build number
gives a build that is always distinguishable, and the App shows it in the form the
user asked for: base + "b" + build (`1.4.0b3`).

Upstream moving to 1.5.0 needs no change here: the base is whatever pubspec says, and
the counter keeps counting — the first build of that base is 1.5.0b1 if the build
number is reset to 1 at the same time, so `--reset` exists for that case.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

TIME = re.compile(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", re.MULTILINE)
BASE_ONLY = re.compile(r"^version:\s*(\d+\.\d+\.\d+)\s*$", re.MULTILINE)


def read(path: Path) -> tuple[str, int]:
    text = path.read_text(encoding="utf-8")
    found = TIME.search(text)
    if found:
        return found.group(1), int(found.group(2))
    # A base version with no build number yet: the first bump makes it +1.
    found = BASE_ONLY.search(text)
    if found:
        return found.group(1), 0
    raise SystemExit(f"{path}: no `version: x.y.z+build` line")


def write(path: Path, base: str, build: int) -> None:
    text = path.read_text(encoding="utf-8")
    line = f"version: {base}+{build}"
    if TIME.search(text):
        text = TIME.sub(line, text, count=1)
    elif BASE_ONLY.search(text):
        text = BASE_ONLY.sub(line, text, count=1)
    else:
        raise SystemExit(f"{path}: no `version:` line to replace")
    path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pubspec", default="app/pubspec.yaml")
    parser.add_argument("--reset", action="store_true", help="start the counter again at 1")
    parser.add_argument("--check", action="store_true", help="print the current display version")
    parser.add_argument("--set-base", default=None, help="adopt an upstream base version")
    args = parser.parse_args()

    path = Path(args.pubspec)
    base, build = read(path)

    if args.check:
        print(f"{base}b{build}")
        return 0

    if args.set_base:
        base = args.set_base
    build = 1 if args.reset else build + 1
    write(path, base, build)
    print(f"{base}+{build}  → 显示为 {base}b{build}")
    return 0


if __name__ == "__main__":
    sys.exit(main())