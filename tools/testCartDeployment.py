#!/usr/bin/env python3
"""Rehearse Cart deployment on a disposable local node. Never contacts a public chain."""

import http.server
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
# Public default Anvil fixture account, used only with the loopback node below.
KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
OWNER = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"


class DeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in ("anvil", "cast", "forge", "git"):
            if not shutil.which(tool):
                raise RuntimeError("Missing required tool: " + tool)
        cls.temp = tempfile.TemporaryDirectory(prefix="cart-deployment-")
        cls.folder = Path(cls.temp.name)
        cls.checkout = cls.folder / "checkout"
        cls.checkout.mkdir()
        for source in ("src/cart", "script/cart"):
            shutil.copytree(ROOT / source, cls.checkout / source)
        (cls.checkout / "script/NetworkConfig.s.sol").write_bytes((ROOT / "script/NetworkConfig.s.sol").read_bytes())
        for name in ("foundry.toml", "remappings.txt", ".gitmodules"):
            shutil.copy2(ROOT / name, cls.checkout / name)
        for dependency, source in (("forge-std", "src"), ("ds-test", "src"),
                                   ("openzeppelin-contracts", "contracts"),
                                   ("openzeppelin-contracts-upgradeable", "contracts")):
            shutil.copytree(ROOT / "lib" / dependency / source,
                            cls.checkout / "lib" / dependency / source)
        (cls.checkout / ".gitignore").write_text("lib/\nout/\ncache/\nbroadcast/\n*.env\n")
        cls.env_file = cls.folder / "empty.env"
        cls.env_file.touch()
        for args in (("init", "-q", "-b", "rehearsal"),
                     ("config", "user.name", "Cart deployment test"),
                     ("config", "user.email", "cart-test@example.invalid"),
                     ("add", "."), ("commit", "-qm", "Deployment fixture")):
            cls.git(*args)
        subprocess.run(["git", "init", "--bare", "-q", str(cls.folder / "remote.git")], check=True)
        cls.git("remote", "add", "origin", str(cls.folder / "remote.git"))
        cls.git("push", "-qu", "origin", "rehearsal")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        cls.node_url = "http://127.0.0.1:" + str(port)
        cls.node_log = (cls.folder / "anvil.log").open("w")
        cls.node = subprocess.Popen(["anvil", "--host", "127.0.0.1", "--port", str(port),
                                     "--chain-id", "11155111", "--silent"],
                                    stdout=cls.node_log, stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                cls.rpc("eth_chainId")
                break
            except (OSError, ValueError):
                time.sleep(0.1)
        else:
            raise RuntimeError("Local Anvil did not start")
        cls.records = []

        class Proxy(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                if self.path != "/":
                    self.send_error(401)
                    return
                body = self.rfile.read(int(self.headers["Content-Length"]))
                request = json.loads(body)
                upstream = urllib.request.Request(cls.node_url, body, {"Content-Type": "application/json"})
                with urllib.request.urlopen(upstream, timeout=120) as response:
                    result = response.read()
                calls = request if isinstance(request, list) else [request]
                replies = json.loads(result)
                replies = replies if isinstance(replies, list) else [replies]
                for call in calls:
                    reply = next((r for r in replies if r.get("id") == call.get("id")), {})
                    cls.records.append((call, reply))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(result)

        cls.proxy = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
        cls.thread = threading.Thread(target=cls.proxy.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = "http://127.0.0.1:" + str(cls.proxy.server_port)
        cls.env = dict(os.environ, RPC_URL=cls.url, PRIVATE_KEY=KEY, CART_PLATFORM_SIGNER=OWNER,
                       CART_CHAIN_ID="11155111", CART_GAS_ESTIMATE_MULTIPLIER="150",
                       CART_EXPECTED_REF="origin/rehearsal", CART_ENV_FILE=str(cls.env_file), NO_COLOR="1")
        cls.env.pop("ETHERSCAN_API_KEY", None)
        # Deployment wiring needs only code existence at these external addresses.
        # This test does not claim to exercise WETH, Permit2, or router behavior.
        section = (cls.checkout / "script/NetworkConfig.s.sol").read_text().split("function _ethereumSepolia()", 1)[1]
        for field in ("weth", "permit2", "universalRouter"):
            address = re.search(r"config\." + field + r" = _addr\((0x[0-9a-fA-F]{40})\)", section)[1]
            cls.rpc("anvil_setCode", address, "0x00")

    @classmethod
    def git(cls, *args):
        return subprocess.check_output(["git", *args], cwd=cls.checkout, stderr=subprocess.STDOUT, text=True)

    @classmethod
    def rpc(cls, method, *params):
        request = urllib.request.Request(cls.node_url, json.dumps({"jsonrpc": "2.0", "id": 1,
                                        "method": method, "params": list(params)}).encode(),
                                        {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(result["error"])
        return result["result"]

    @classmethod
    def tearDownClass(cls):
        cls.proxy.shutdown()
        cls.proxy.server_close()
        cls.node.terminate()
        cls.node.wait(timeout=10)
        cls.node_log.close()
        cls.temp.cleanup()

    def wrapper(self, *args, **env):
        return subprocess.run(["bash", "script/cart/deploy.sh", *args], cwd=self.checkout,
                              env=self.env | env, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=600)

    def rejected_without_send(self, expected, *args, **env):
        start = len(self.records)
        result = self.wrapper(*args, **env)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(expected, result.stdout)
        self.assertFalse(any(call["method"] == "eth_sendRawTransaction" for call, _ in self.records[start:]))
        self.assertNotIn("Compiling", result.stdout)
        return result

    def test_rpc_auth_failure_redacts_endpoint(self):
        result = self.rejected_without_send("RPC preflight failed", RPC_URL=self.url + "/credential-marker")
        self.assertNotIn("credential-marker", result.stdout)

    def test_wrong_chain_stops_before_compilation(self):
        self.rejected_without_send("does not match CART_CHAIN_ID", CART_CHAIN_ID="1")

    def test_verification_requires_api_key_before_broadcast(self):
        self.rejected_without_send("ETHERSCAN_API_KEY", "--broadcast", "--verify")

    def test_resume_requires_broadcast(self):
        self.rejected_without_send("require --broadcast", "--resume")

    def test_gas_margin_cannot_reduce_node_estimate(self):
        self.rejected_without_send("at least 100", CART_GAS_ESTIMATE_MULTIPLIER="99")

    def test_complete_suite_uses_sequential_node_estimates(self):
        start = len(self.records)
        result = self.wrapper("--broadcast")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("Missing dependencies found", result.stdout)
        broadcast = json.loads((self.checkout / "broadcast/CartDeploy.s.sol/11155111/run-latest.json").read_text())
        expected = {"CartRoutePolicy", "CartPayments", "Cart", "ERC1967Proxy", "CartLens", "CartHashes"}
        transactions = broadcast["transactions"]
        self.assertEqual({t["contractName"] for t in transactions}, expected)
        self.assertEqual(len(transactions), 6)
        receipts = {r["transactionHash"]: r for r in broadcast["receipts"]}
        estimates = [int(reply["result"], 16) for call, reply in self.records[start:]
                     if call["method"] == "eth_estimateGas" and "result" in reply]
        self.assertGreaterEqual(len(estimates), 6)
        for tx in transactions:
            receipt = receipts[tx["hash"]]
            self.assertEqual(receipt["status"], "0x1")
            actual_tx = self.rpc("eth_getTransactionByHash", tx["hash"])
            self.assertIn(int(actual_tx["gas"], 16), [estimate * 150 // 100 for estimate in estimates])
            self.assertNotEqual(self.rpc("eth_getCode", tx["contractAddress"], "latest"), "0x")
        # Each transaction must have a confirmed receipt before the next submission.
        pending = None
        for call, reply in self.records[start:]:
            if call["method"] == "eth_sendRawTransaction":
                self.assertIsNone(pending)
                pending = reply["result"]
            if call["method"] == "eth_getTransactionReceipt" and reply.get("result"):
                if call["params"][0] == pending:
                    pending = None
        self.assertIsNone(pending)
        # A completed broadcast can resume without rerunning run() or resending transactions.
        nonce = self.rpc("eth_getTransactionCount", OWNER, "latest")
        resume_start = len(self.records)
        resumed = self.wrapper("--broadcast", "--resume")
        self.assertEqual(resumed.returncode, 0, resumed.stdout)
        self.assertEqual(self.rpc("eth_getTransactionCount", OWNER, "latest"), nonce)
        self.assertFalse(any(call["method"] == "eth_sendRawTransaction" for call, _ in self.records[resume_start:]))
        addresses = {t["contractName"]: t["contractAddress"].lower() for t in transactions}
        proxy = addresses["ERC1967Proxy"]
        self.assertEqual("0x" + self.rpc("eth_getStorageAt", proxy, IMPLEMENTATION_SLOT, "latest")[-40:], addresses["Cart"])
        for field, typ, value in (("owner", "address", OWNER), ("platformSigner", "address", OWNER),
                                  ("paused", "bool", "false"), ("routePolicy", "address", addresses["CartRoutePolicy"])):
            actual = subprocess.check_output(["cast", "call", proxy, field + "()(" + typ + ")",
                                              "--rpc-url", self.url], text=True).strip().lower()
            self.assertEqual(actual, value)
        # The independent Lens command remains available and does not redeploy Cart.
        lens = subprocess.run(["bash", "script/cart/deploy-lens.sh", "--broadcast"], cwd=self.checkout,
                              env=self.env, text=True, capture_output=True, timeout=120)
        self.assertEqual(lens.returncode, 0, lens.stdout + lens.stderr)
        independent = json.loads((self.checkout / "broadcast/CartLensDeploy.s.sol/11155111/run-latest.json").read_text())
        self.assertEqual([t["contractName"] for t in independent["transactions"]], ["CartLens"])
        self.assertEqual(self.git("status", "--porcelain"), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
