#!/usr/bin/env python3
"""Deploy the reconciled Sepolia Cart with live RPC gas estimates and confirmed receipts."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid


ROOT = Path(__file__).resolve().parents[1]
CHAIN_ID = 11155111
IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
FIELDS = {
    "owner": "address",
    "platformSigner": "address",
    "universalRouter": "address",
    "permit2": "address",
    "weth": "address",
    "protocolRecipient": "address",
    "paused": "bool",
    "routePolicy": "address",
    "DOMAIN_SEPARATOR": "bytes32",
}


def redact(message):
    for key, value in os.environ.items():
        if value and any(part in key.upper() for part in ("PRIVATE_KEY", "RPC_URL", "API_KEY", "PASSWORD", "SECRET")):
            message = message.replace(value, "<REDACTED>")
    return re.sub(r"https?://[^\s]+", "<REDACTED_URL>", message)


def run(*args, timeout=90):
    environment = dict(os.environ)
    environment.pop("CAST_ASYNC", None)
    try:
        result = subprocess.run(
            ["cast", *args], cwd=ROOT, env=environment, text=True,
            capture_output=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("Cast timed out. Inspect the deployment ledger and signer nonce before any retry.") from None
    if result.returncode:
        raise RuntimeError(redact(result.stderr or "Cast failed without diagnostics."))
    return result.stdout.strip()


def configured_addresses():
    source = (ROOT / "script/NetworkConfig.s.sol").read_text()
    section = source.split("function _ethereumSepolia()", 1)[1].split("\n  function ", 1)[0]
    return {
        field: address.lower()
        for field, address in re.findall(r"config\.(\w+)\s*=\s*_addr\((0x[0-9a-fA-F]{40})\)", section)
    }


class Upgrade:
    def __init__(self):
        self.rpc = os.environ["RPC_URL"]
        self.key = os.environ["PRIVATE_KEY"]
        self.config = configured_addresses()
        self.proxy = self.config["cartProxy"]
        if os.environ.get("CART_PROXY", self.proxy).lower() != self.proxy:
            raise RuntimeError("CART_PROXY differs from the configured Sepolia proxy.")
        self.multiplier = int(os.environ.get("CART_GAS_ESTIMATE_MULTIPLIER", "150"))
        if self.multiplier < 100:
            raise RuntimeError("CART_GAS_ESTIMATE_MULTIPLIER must be at least 100.")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.folder = ROOT / "broadcast/cart-free-listings" / (stamp + "-" + uuid.uuid4().hex[:8])
        self.folder.mkdir(parents=True)
        self.report = {
            "chainId": CHAIN_ID, "proxy": self.proxy, "contracts": {}, "transactions": [],
            "artifactSha256": {}, "sourceSha256": {}, "status": "preflight",
        }
        self.artifacts = {}
        source_hashes = {}
        for name in ("CartPayments", "Cart", "CartLens"):
            contents = (ROOT / "out" / (name + ".sol") / (name + ".json")).read_bytes()
            artifact = json.loads(contents)
            self.artifacts[name] = artifact
            self.report["artifactSha256"][name] = hashlib.sha256(contents).hexdigest()
            metadata = artifact["metadata"]
            if isinstance(metadata, str):
                metadata = json.loads(metadata)
            if not metadata.get("sources"):
                raise RuntimeError(name + " artifact has no source hashes. Rebuild before broadcasting.")
            for source, description in metadata["sources"].items():
                if source not in source_hashes:
                    contents = (ROOT / source).read_bytes()
                    source_hashes[source] = run("keccak", "0x" + contents.hex()).lower()
                    self.report["sourceSha256"][source] = hashlib.sha256(contents).hexdigest()
                if source_hashes[source] != description["keccak256"].lower():
                    raise RuntimeError("Stale compiled artifact for " + source + ". Rebuild before broadcasting.")
        self.save()

    def save(self):
        temporary = self.folder / "deployment.json.tmp"
        temporary.write_text(json.dumps(self.report, indent=2) + "\n")
        temporary.replace(self.folder / "deployment.json")

    def rpc_call(self, method, *params):
        return json.loads(run("rpc", "--rpc-url", self.rpc, method, *params))

    def state(self):
        values = {
            field: run("call", self.proxy, field + "()(" + result_type + ")", "--rpc-url", self.rpc).lower()
            for field, result_type in FIELDS.items()
        }
        slot = self.rpc_call("eth_getStorageAt", self.proxy, IMPLEMENTATION_SLOT, "latest")
        values["implementation"] = "0x" + slot[-40:].lower()
        return values

    def require_nonce(self):
        latest = int(self.rpc_call("eth_getTransactionCount", self.owner, "latest"), 16)
        pending = int(self.rpc_call("eth_getTransactionCount", self.owner, "pending"), 16)
        if latest != pending or latest != self.next_nonce:
            raise RuntimeError("Signer nonce changed or has pending transactions. Stop and inspect before retrying.")

    def require_unchanged_state(self):
        if self.state() != self.baseline:
            raise RuntimeError("Cart state changed during deployment; the proxy upgrade was not submitted.")

    def send(self, name, creation=None, call=None):
        self.require_nonce()
        payload = ["--create", creation] if creation else list(call)
        estimate = int(run("estimate", "--rpc-url", self.rpc, "--from", self.owner, *payload))
        limit = (estimate * self.multiplier + 99) // 100
        row = {"label": name, "nonce": self.next_nonce, "estimateGas": estimate, "gasLimit": limit, "status": "submitting"}
        self.report["transactions"].append(row)
        self.save()
        if name == "Upgrade":
            self.require_unchanged_state()
        self.require_nonce()
        print(f"{name}: live estimate {estimate:,}; gas limit {limit:,}; nonce {self.next_nonce}", flush=True)
        transaction_hash = run(
            "send", "--rpc-url", self.rpc, "--private-key", self.key, "--chain", str(CHAIN_ID),
            "--nonce", str(self.next_nonce), "--gas-limit", str(limit), "--async", *payload,
        )
        if not re.fullmatch(r"0x[0-9a-fA-F]{64}", transaction_hash):
            raise RuntimeError("Cast did not return a transaction hash. Inspect signer history before any retry.")
        row.update({"hash": transaction_hash, "status": "submitted"})
        self.save()
        receipt = json.loads(run("receipt", transaction_hash, "--rpc-url", self.rpc, "--json", timeout=240))
        row["receipt"] = receipt
        self.save()
        if receipt.get("status") not in (1, "1", "0x1"):
            raise RuntimeError(f"{name} reverted: {transaction_hash}")
        if receipt.get("transactionHash", "").lower() != transaction_hash.lower():
            raise RuntimeError("Receipt transaction hash does not match the submitted transaction.")
        if receipt.get("from", "").lower() != self.owner:
            raise RuntimeError("Receipt sender does not match the Cart owner.")
        address = receipt.get("contractAddress")
        if creation:
            if not isinstance(address, str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", address) or int(address, 16) == 0:
                raise RuntimeError("Successful creation receipt has no valid contract address.")
            self.report["contracts"][name] = address.lower()
        elif receipt.get("to", "").lower() != self.proxy:
            raise RuntimeError("Upgrade receipt destination differs from the configured proxy.")
        row["status"] = "confirmed"
        self.next_nonce += 1
        self.save()
        print(f"{name}: confirmed {transaction_hash}", flush=True)
        return address.lower() if address else None

    def deploy(self, name, constructor_types=None, arguments=()):
        artifact = self.artifacts[name]
        creation = artifact["bytecode"]["object"]
        if constructor_types:
            creation += run("abi-encode", "constructor(" + constructor_types + ")", *arguments).removeprefix("0x")
        address = self.send(name, creation=creation)
        deployed = artifact["deployedBytecode"]
        expected = bytearray.fromhex(deployed["object"].removeprefix("0x"))
        actual = bytearray.fromhex(self.rpc_call("eth_getCode", address, "latest").removeprefix("0x"))
        if len(actual) != len(expected) or not actual:
            raise RuntimeError(name + " deployed runtime length differs from the local artifact.")
        allowed = {address, self.baseline["routePolicy"], *self.report["contracts"].values()}
        immutable_values = []
        for references in deployed.get("immutableReferences", {}).values():
            for reference in references:
                start, length = reference["start"], reference["length"]
                word = actual[start:start + length]
                if length != 32 or any(word[:12]) or "0x" + word[12:].hex() not in allowed:
                    raise RuntimeError(name + " contains an unexpected immutable value.")
                immutable_values.append("0x" + word[12:].hex())
                expected[start:start + length] = bytes(length)
                actual[start:start + length] = bytes(length)
        if actual != expected:
            raise RuntimeError(name + " deployed runtime differs from the local artifact.")
        self.report.setdefault("runtimeVerification", {})[name] = {"matches": True, "immutableAddresses": sorted(set(immutable_values))}
        self.save()
        return address

    def execute(self):
        if int(run("chain-id", "--rpc-url", self.rpc)) != CHAIN_ID:
            raise RuntimeError("This upgrade helper is restricted to Sepolia chain 11155111.")
        self.owner = run("wallet", "address", "--private-key", self.key).lower()
        self.baseline = self.state()
        if self.baseline["owner"] != self.owner:
            raise RuntimeError("PRIVATE_KEY does not belong to the current Cart owner.")
        expected = {
            "implementation": "cartImplementation", "routePolicy": "cartRoutePolicy",
            "universalRouter": "universalRouter", "permit2": "permit2", "weth": "weth",
        }
        for field, config_field in expected.items():
            if self.baseline[field] != self.config[config_field]:
                raise RuntimeError("Live " + field + " differs from NetworkConfig.")
        self.next_nonce = int(self.rpc_call("eth_getTransactionCount", self.owner, "latest"), 16)
        self.require_nonce()
        self.report.update({"owner": self.owner, "baseline": self.baseline, "startNonce": self.next_nonce, "status": "deploying"})
        self.save()
        payments = self.deploy("CartPayments", "address", (self.baseline["routePolicy"],))
        implementation = self.deploy("Cart", "address,address", (self.baseline["routePolicy"], payments))
        self.deploy("CartLens")
        self.require_unchanged_state()
        self.send("Upgrade", call=(self.proxy, "upgradeToAndCall(address,bytes)", implementation, "0x"))
        expected_state = {**self.baseline, "implementation": implementation}
        after = self.state()
        self.report["postflight"] = after
        if after != expected_state:
            raise RuntimeError("Proxy postflight state does not match the expected upgraded state.")
        self.report["status"] = "complete"
        self.save()
        print("Sepolia Cart upgrade verified. Ledger: " + str(self.folder / "deployment.json"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--broadcast", action="store_true", required=True, help="Submit the four upgrade transactions.")
    parser.parse_args()
    subprocess.run(["bash", str(ROOT / "script/cart/check-checkout.sh"), "--remote"], cwd=ROOT, check=True)
    upgrade = Upgrade()
    try:
        upgrade.execute()
    except Exception as error:
        upgrade.report.update({"status": "stopped", "error": redact(str(error))})
        upgrade.save()
        raise RuntimeError(redact(str(error)) + " Ledger: " + str(upgrade.folder / "deployment.json")) from None


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(redact(str(error)), file=sys.stderr)
        sys.exit(1)
