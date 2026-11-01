#!/usr/bin/env python3
"""Rebuild the pinned pre-split migration fixture with the local Solidity toolchain."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REVISION = 'a33db9aa71eb700378789c3d58551cc2720949b8'
with tempfile.TemporaryDirectory(prefix='cart-pre-split-') as directory:
    target = Path(directory)
    archive = subprocess.check_output(['git', 'archive', REVISION, 'src/cart'], cwd=ROOT)
    subprocess.run(['tar', '-x', '-C', directory], input=archive, check=True)
    for name in ['foundry.toml', 'remappings.txt']:
        shutil.copy(ROOT / name, target / name)
    (target / 'lib').symlink_to(ROOT / 'lib', target_is_directory=True)
    import os
    environment = dict(os.environ, FOUNDRY_PROFILE='cart')
    subprocess.run(['forge', 'build', '--root', directory, '--offline'], env=environment, check=True)
    result = {'revision': REVISION, 'compiler': 'solc 0.8.18; viaIR; optimizer_runs=100'}
    for name in ['Cart', 'CartPayments']:
        artifact = json.loads((target / 'out' / (name + '.sol') / (name + '.json')).read_text())
        result[name] = artifact['bytecode']['object']
    destination = ROOT / 'docs/data/cart-pre-split-bytecode.json'
    destination.write_text(json.dumps(result, indent=2) + '\n')
