#!/usr/bin/env python3
"""Add Icon: fields to Packages stanzas for published package icons."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <repo-dir> <base-url>", file=sys.stderr)
        return 1

    repo_dir = Path(sys.argv[1])
    base_url = sys.argv[2].rstrip("/")
    packages_path = repo_dir / "Packages"
    icons_dir = repo_dir / "icons"

    if not packages_path.is_file():
        print(f"Missing Packages file: {packages_path}", file=sys.stderr)
        return 1

    text = packages_path.read_text(encoding="utf-8")
    stanzas = [s for s in text.split("\n\n") if s.strip()]
    updated: list[str] = []

    for stanza in stanzas:
        match = re.search(r"^Package: (.+)$", stanza, re.MULTILINE)
        if not match:
            updated.append(stanza)
            continue

        package = match.group(1).strip()
        icon_file = icons_dir / f"{package}.png"
        if not icon_file.is_file():
            updated.append(stanza)
            continue

        icon_url = f"{base_url}/icons/{package}.png"
        if re.search(r"^Icon:", stanza, re.MULTILINE):
            stanza = re.sub(
                r"^Icon:.*$",
                f"Icon: {icon_url}",
                stanza,
                count=1,
                flags=re.MULTILINE,
            )
        else:
            stanza = re.sub(
                r"^(Package: .+)$",
                rf"\1\nIcon: {icon_url}",
                stanza,
                count=1,
                flags=re.MULTILINE,
            )

        updated.append(stanza)

    packages_path.write_text("\n\n".join(updated) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
