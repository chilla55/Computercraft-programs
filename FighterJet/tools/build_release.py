#!/usr/bin/env python3
"""Generate the immutable-tag manifest and optional manual-copy ZIP."""
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
version = sys.argv[1] if len(sys.argv) > 1 else 'fighter-0.1.8'
assert re.fullmatch(r'fighter-\d+\.\d+\.\d+', version), 'Expected fighter-X.Y.Z'
names = ['flight.lua', 'flight_core.lua', 'hardware.lua', 'jet_config.lua', 'jet_link.lua',
         'jet_store.lua', 'jet_paths.lua', 'hud.lua', 'hud_core.lua', 'hud_data.lua',
         'cockpit_ui.lua', 'startup.lua', 'startup_mode.lua', 'install.lua']
manifest = {'schema': 1, 'version': version, 'ref': version, 'files': {}}
for name in names:
    body = (root / name).read_bytes()
    manifest['files'][name] = {'size': len(body), 'sha256': hashlib.sha256(body).hexdigest()}
(root / 'release.json').write_text(json.dumps(manifest, indent=2) + '\n')
with zipfile.ZipFile(root / 'fighter-release.zip', 'w', zipfile.ZIP_DEFLATED) as bundle:
    for name in names + ['README.md', 'release.json']:
        bundle.write(root / name, name)
print(f'{version}: {len(names)} verified Lua files, {sum(e["size"] for e in manifest["files"].values())} bytes')
