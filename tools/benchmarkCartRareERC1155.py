#!/usr/bin/env python3
"""Run real-token Cart benchmarks in an isolated project; never edits workspace contracts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--erc721', action='store_true', help='Benchmark LazySovereignNFT instead of RareERC1155')
parser.add_argument('--expanded', action='store_true', help='Compatibility flag; current source has no resource count caps')
parser.add_argument('--build-dir', type=Path, help='New directory for sources, compiler cache, logs, and results')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
if args.build_dir:
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=False)
else:
    build = Path(tempfile.mkdtemp(prefix='cart-erc721-' if args.erc721 else 'cart-rare1155-'))
for directory in ('src/cart', 'src/token'):
    shutil.copytree(repo / directory, build / directory)
(build / 'src/test/cart').mkdir(parents=True)
benchmark_file = 'CartERC721Gas.t.sol' if args.erc721 else 'CartRareERC1155Gas.t.sol'
for name in ('Cart.t.sol', 'CartListingGas.t.sol', benchmark_file):
    shutil.copyfile(repo / 'src/test/cart' / name, build / 'src/test/cart' / name)
for name in ('foundry.toml', 'remappings.txt'):
    shutil.copyfile(repo / name, build / name)
(build / 'lib').symlink_to((repo / 'lib').resolve(), target_is_directory=True)
env = dict(os.environ, FOUNDRY_PROFILE='cart')
benchmark_contract = 'CartERC721GasTest' if args.erc721 else 'CartRareERC1155GasTest'
benchmark_pattern = '^testERC721' if args.erc721 else '^testRare'
event_name = 'ERC721Gas' if args.erc721 else 'RareERC1155Gas'
command = ['forge', 'test', '--offline', '--root', str(build), '--match-contract', benchmark_contract, '--match-test', benchmark_pattern, '-vvvv']
print(f'Benchmark project: {build}', flush=True)
print('Current workspace source, without resource count caps', flush=True)
with (build / 'results.log').open('w') as output:
    result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT)
log = (build / 'results.log').read_text()
if result.returncode or '[FAIL' in log:
    print(log[-6000:])
    raise SystemExit(result.returncode or 1)
rows = []
for line in log.splitlines():
    if f'emit {event_name}(' not in line:
        continue
    numbers = dict(re.findall(r'(\w+): (\d+)', line))
    row = {name: int(numbers[name]) for name in ('sales', 'lines', 'calldataBytes', 'grossCallGas', 'intrinsicGas', 'calldataFloorGas')}
    row['mode'] = 'mint' if 'minting: true' in line else 'transfer'
    row['approximateTransactionGas'] = max(row['grossCallGas'] + row['intrinsicGas'], row['calldataFloorGas'])
    row['bufferedGasLimit'] = (row['approximateTransactionGas'] * 125 + 99) // 100
    rows.append(row)
expected = {(mode, n) for mode in ('mint', 'transfer') for n in (9, 18, 32, 62, 64)}
assert {(r['mode'], r['sales']) for r in rows} == expected and len(rows) == len(expected)
token_source = 'src/token/ERC721/sovereign/lazy/LazySovereignNFT.sol' if args.erc721 else 'src/token/ERC1155/RareERC1155.sol'
method = ('Minimal-proxy LazySovereignNFT; one collection; one EOA buyer; two fee lines; transfers preminted, or fresh mints with per-token royalties. ' if args.erc721 else 'Factory-cloned RareERC1155; one collection; distinct IDs; one EOA buyer; shared seller root; two fee lines; transfer leaves one seller unit, mint begins with zero supply. ') + 'Native payment; gross call plus intrinsic subject to calldata floor; excludes fixture preparation and refunds, not receipts or RPC estimates.'
report = {'token_standard': 'ERC721' if args.erc721 else 'ERC1155', 'expanded_caps': False, 'line_cap': None, 'operation_cap': None,
    'method': method,
    'source_sha256': {name: hashlib.sha256((build / name).read_bytes()).hexdigest() for name in ('src/cart/Cart.sol', 'src/cart/CartHashing.sol', token_source, 'src/test/cart/' + benchmark_file)},
    'results': sorted(rows, key=lambda r: (r['sales'], r['mode']))}
(build / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print('| Sales | Lines | Transfer gas | Mint gas |')
print('| ---: | ---: | ---: | ---: |')
for n in sorted({r['sales'] for r in rows}):
    values = {r['mode']: r for r in rows if r['sales'] == n}
    print(f"| {n} | {n + 2} | {values['transfer']['approximateTransactionGas']:,} | {values['mint']['approximateTransactionGas']:,} |")
print(f'Raw log and JSON: {build}')
