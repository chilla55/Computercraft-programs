"""Generate hashes for a versioned release; commit and tag the same file tree."""
import hashlib
import json
from pathlib import Path
import re
root = Path(__file__).resolve().parent.parent
version = re.search(r"release='(distributed-\d+\.\d+\.\d+)'", (root / 'common.lua').read_text()).group(1)
names = ['app', 'common', 'runtime', 'protection', 'regulation', 'planner', 'ui', 'interface', 'updater', 'sha256', 'thermal_protection', 'transformer']
manifest = {'schema': 1, 'version': version, 'ref': version, 'files': {}}
for name in names:
    filename = name + '.lua'
    body = (root / filename).read_bytes()
    manifest['files'][filename] = {'size': len(body), 'sha256': hashlib.sha256(body).hexdigest()}
(root / 'release.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
print(f'Built {version}: {len(names)} files, {sum(f["size"] for f in manifest["files"].values())} bytes')
