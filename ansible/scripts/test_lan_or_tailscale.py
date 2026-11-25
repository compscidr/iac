#!/usr/bin/env python3
"""Tests for lan-or-tailscale. Run: python3 ansible/scripts/test_lan_or_tailscale.py"""

import importlib.machinery
import importlib.util
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lan-or-tailscale")


def load():
    sys.dont_write_bytecode = True  # no __pycache__ beside the script
    loader = importlib.machinery.SourceFileLoader("lan_or_tailscale", SCRIPT)
    spec = importlib.util.spec_from_loader("lan_or_tailscale", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


lot = load()


class Probe:
    """Stands in for the network check and records what it was asked."""

    def __init__(self, answer):
        self.answer = answer
        self.calls = []

    def __call__(self, host):
        self.calls.append(host)
        return self.answer


class ChooseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cache = os.path.join(self.tmp.name, "cache")

    def choose(self, name, probe, now=1000.0, ttl=300):
        return lot.choose(name, self.cache, ttl, probe, now)

    def test_reachable_local_name_is_kept(self):
        probe = Probe(True)
        self.assertEqual(self.choose("ubuntu-beast.local", probe), "ubuntu-beast.local")
        self.assertEqual(probe.calls, ["ubuntu-beast.local"])

    def test_unreachable_local_name_falls_back_to_tailscale_name(self):
        self.assertEqual(self.choose("ubuntu-beast.local", Probe(False)), "ubuntu-beast")

    def test_name_without_local_suffix_is_returned_without_probing(self):
        probe = Probe(False)
        self.assertEqual(self.choose("www", probe), "www")
        self.assertEqual(probe.calls, [])

    def test_answer_is_reused_within_ttl(self):
        self.choose("ubuntu-beast.local", Probe(False), now=1000.0)
        probe = Probe(True)
        self.assertEqual(self.choose("ubuntu-beast.local", probe, now=1299.0), "ubuntu-beast")
        self.assertEqual(probe.calls, [])

    def test_answer_is_rechecked_after_ttl(self):
        self.choose("ubuntu-beast.local", Probe(False), now=1000.0)
        probe = Probe(True)
        self.assertEqual(self.choose("ubuntu-beast.local", probe, now=1301.0), "ubuntu-beast.local")
        self.assertEqual(probe.calls, ["ubuntu-beast.local"])

    def test_hosts_are_cached_separately(self):
        self.choose("ubuntu-beast.local", Probe(False))
        self.assertEqual(self.choose("ubuntu-cube.local", Probe(True)), "ubuntu-cube.local")

    def test_unusable_cache_dir_still_answers(self):
        blocker = os.path.join(self.tmp.name, "file")
        with open(blocker, "w", encoding="utf-8"):
            pass
        self.cache = os.path.join(blocker, "cache")
        self.assertEqual(self.choose("ubuntu-beast.local", Probe(False)), "ubuntu-beast")

    def test_garbage_in_cache_file_is_ignored(self):
        os.makedirs(self.cache)
        path = os.path.join(self.cache, "ubuntu-beast.local")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("evil.example.com\n")
        os.utime(path, (1000.0, 1000.0))
        self.assertEqual(self.choose("ubuntu-beast.local", Probe(True)), "ubuntu-beast.local")

    def test_name_that_is_not_a_hostname_is_rejected(self):
        for bad in ("../etc/passwd.local", "a b.local", "", "-oProxyCommand=x.local"):
            with self.assertRaises(ValueError, msg=bad):
                self.choose(bad, Probe(True))


class ProbeTest(unittest.TestCase):
    def test_open_port_is_reachable(self):
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            port = server.getsockname()[1]
            self.assertTrue(lot.probe("127.0.0.1", port, 2.0))

    def test_closed_port_is_not_reachable(self):
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            port = server.getsockname()[1]
        self.assertFalse(lot.probe("127.0.0.1", port, 2.0))

    def test_slow_lookup_is_cut_off_at_the_timeout(self):
        # A failed mDNS lookup blocks for ~5 s inside getaddrinfo, which no
        # socket timeout covers. The whole probe has to give up on time.
        def hang(*_args, **_kwargs):
            time.sleep(5)
            raise OSError("too late")

        original = lot.socket.create_connection
        lot.socket.create_connection = hang
        self.addCleanup(setattr, lot.socket, "create_connection", original)
        started = time.monotonic()
        self.assertFalse(lot.probe("ubuntu-beast.local", 22, 0.3))
        self.assertLess(time.monotonic() - started, 1.5)


class CommandLineTest(unittest.TestCase):
    def run_script(self, *args, cache):
        env = dict(os.environ, LAN_OR_TAILSCALE_CACHE_DIR=cache, LAN_OR_TAILSCALE_TIMEOUT="0.5")
        return subprocess.run(
            [sys.executable, SCRIPT, *args], env=env, capture_output=True, text=True, timeout=30, check=False
        )

    def test_unreachable_host_prints_the_tailscale_name(self):
        with tempfile.TemporaryDirectory() as cache:
            started = time.monotonic()
            result = self.run_script("no-such-host-for-lan-or-tailscale.local", cache=cache)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "no-such-host-for-lan-or-tailscale\n")
            # The process must not linger on the abandoned lookup.
            self.assertLess(time.monotonic() - started, 3)

    def test_missing_argument_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as cache:
            result = self.run_script(cache=cache)
            self.assertEqual(result.returncode, 2)
            self.assertIn("usage", result.stderr)

    def test_bad_name_is_an_error(self):
        with tempfile.TemporaryDirectory() as cache:
            result = self.run_script("../x.local", cache=cache)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
