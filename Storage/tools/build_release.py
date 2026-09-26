"""Regenerate the monitor release manifest after increasing its version header."""
import hashlib
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
body = (root / "stock_monitor.lua").read_bytes()
match = re.match(rb"-- stock-monitor-version: (\d+\.\d+\.\d+)\n", body)
if not match:
    raise SystemExit("Missing stock-monitor-version header")
manifest = {
    "schema": 1,
    "version": match[1].decode("ascii"),
    "size": len(body),
    "sha256": hashlib.sha256(body).hexdigest(),
}
(root / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Built storage monitor {manifest['version']}")
