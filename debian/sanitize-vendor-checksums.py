#!/usr/bin/env python3
"""Remove checksum entries for files absent from the vendored tree."""

from __future__ import annotations

import json
from pathlib import Path


def main() -> int:
    vendor = Path("vendor")
    if not vendor.is_dir():
        return 0
    for checksum in vendor.rglob(".cargo-checksum.json"):
        data = json.loads(checksum.read_text(encoding="utf-8"))
        files = data.get("files")
        if not isinstance(files, dict):
            continue
        missing = [
            name
            for name in files
            if name.endswith(".orig") or not (checksum.parent / name).exists()
        ]
        for name in missing:
            del files[name]
        if missing:
            checksum.write_text(
                json.dumps(data, sort_keys=True) + "\n", encoding="utf-8"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
