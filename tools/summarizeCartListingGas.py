#!/usr/bin/env python3
"""Summarize ListingGas events, excluding fixture construction from the gas metric."""
import argparse
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('log', type=Path)
parser.add_argument('--json', type=Path, dest='output')
args = parser.parse_args()
log = args.log.read_text()
if "[FAIL" in log:
    raise SystemExit("Test failures found; do not publish this run.")
rows = []
for line in log.splitlines():
    if 'emit ListingGas(' not in line:
        continue
    values = dict(re.findall(r'(\w+): (\d+)', line))
    row = {name: int(values[name]) for name in (
        'lines', 'listings', 'calldataBytes', 'grossCallGas',
        'intrinsicGas', 'calldataFloorGas')}
    row['approximateTransactionGas'] = max(
        row['grossCallGas'] + row['intrinsicGas'], row['calldataFloorGas'])
    rows.append(row)
expected = {(n, k) for n in (9, 18, 32, 64) for k in (1, n)}
if len(rows) != 8 or {(r['lines'], r['listings']) for r in rows} != expected:
    raise SystemExit('Expected eight successful benchmark events; check the test log.')
rows.sort(key=lambda r: (r['lines'], r['listings']))
if args.output:
    args.output.write_text(json.dumps(rows, indent=2) + '\n')
print('| Lines | Listings | Calldata bytes | Approximate transaction gas |')
print('| ---: | ---: | ---: | ---: |')
for r in rows:
    print(f"| {r['lines']} | {r['listings']} | {r['calldataBytes']:,} | "
          f"{r['approximateTransactionGas']:,} |")
