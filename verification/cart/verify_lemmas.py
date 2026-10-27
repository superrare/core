"""Check approved trusted rewrites and their independent arithmetic justification.

This is not a kernel certificate for the K rule. K's documented nonnegative,
bounded integer XOR semantics correspond to unsigned 256-bit XOR. The SMT query
checks the complement identity in 257 bits, where the unsigned sum cannot wrap.
Fixed hashes bind that checked formula to the reviewed, range-guarded K rule.
The second query checks word-difference equality using integer modulo, matching
KEVM chop semantics. Neither query is a kernel certificate for a K rewrite.
"""

import hashlib
import json
from pathlib import Path
import subprocess


APPROVED_SHA256 = {
    "word-complement.k": "90fc7afd8940bbaedba71210b4ad462351e269c92bfacb12b0770aa526cffe32",
    "word-complement.smt2": "a0088705bf2cc6dffb3f694a2a215b1e535427f2dfcf425c28e7e2e991d080a8",
    "word-arithmetic.k": "ae1449ab57d6915d533c2e4d637aef2c8159e437a44f690ab37dc30a1986f7c9",
    "word-difference.smt2": "d95f720d95968e3bec6b71c432d3ed730ee0850b454a99f759810240f595cad2",
}


def verify_lemmas():
    """Reject formula/rule drift or an inconclusive solver result; return evidence."""
    directory = Path(__file__).resolve().parent / "lemmas"
    hashes = {}
    for name, expected in APPROVED_SHA256.items():
        actual = hashlib.sha256((directory / name).read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError(f"Unreviewed lemma change: {name}: {actual}")
        hashes[name] = actual

    version = subprocess.run(
        ["z3", "-version"], capture_output=True, text=True, timeout=5, check=True
    ).stdout.strip()
    queries = {}
    for name in ("word-complement.smt2", "word-difference.smt2"):
        result = subprocess.run(
            ["z3", "-smt2", str(directory / name)],
            capture_output=True,
            text=True,
            timeout=45,
            check=False,
        )
        if result.returncode != 0 or result.stdout.strip() != "unsat":
            raise RuntimeError(
                f"Arithmetic query was not proved: {name}: returncode={result.returncode}, "
                f"stdout={result.stdout!r}, stderr={result.stderr!r}"
            )
        queries[name] = "unsat"
    return {"hashes": hashes, "solver_version": version, "result": "unsat", "queries": queries}


if __name__ == "__main__":
    print(json.dumps(verify_lemmas(), indent=2))
