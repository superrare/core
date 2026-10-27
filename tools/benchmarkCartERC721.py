#!/usr/bin/env python3
"""Run the shared real-token benchmark runner for LazySovereignNFT."""
from pathlib import Path
import runpy
import sys

runner = Path(__file__).with_name('benchmarkCartRareERC1155.py')
sys.argv = [str(runner), '--erc721', *sys.argv[1:]]
runpy.run_path(str(runner), run_name='__main__')
