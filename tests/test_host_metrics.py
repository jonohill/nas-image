"""Tests for root/usr/local/sbin/host-metrics.

Run from the repo root with: python3 -m unittest discover -s tests

Each collector runs against saved command output in fixtures/host-metrics
and must reproduce expected/host-<collector>.prom exactly. The dashboard
queries these metric names, so a change to the expected files is a change
to the dashboard's inputs. Regenerate them with UPDATE_EXPECTED=1.
"""

import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "tests" / "fixtures" / "host-metrics"
EXPECTED = FIXTURES / "expected"
NOW = 1791771775.5

# The script lives under root/, which is copied into the image, so loading it
# must not leave a __pycache__ beside it.
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("host_metrics", str(REPO / "root/usr/local/sbin/host-metrics"))
spec = importlib.util.spec_from_loader(loader.name, loader)
hm = importlib.util.module_from_spec(spec)
loader.exec_module(hm)


def fixture(name):
    return (FIXTURES / name).read_text()


def fake_run(*cmd, check=True):
    """Stands in for host-metrics' run(), answering from the fixtures."""
    match cmd:
        case ("/usr/sbin/zpool", "status", *_):
            return fixture("zpool-status.json")
        case ("/usr/sbin/zpool", "list", *_):
            return fixture("zpool-list.txt")
        case ("systemctl", "list-units", *_):
            return fixture("systemctl-failed.txt")
        case ("/usr/sbin/smartctl", "--scan", *_):
            return fixture("smartctl-scan.json")
        case ("/usr/sbin/smartctl", *_, device):
            return fixture(f"smartctl-{device.removeprefix('/dev/')}.json")
        case ("bootc", "status", *_):
            return fixture("bootc-status.json")
    raise AssertionError(f"unexpected command: {cmd}")


class CollectorOutput(unittest.TestCase):
    def run_collector(self, collector):
        with tempfile.TemporaryDirectory() as out, \
                mock.patch.object(hm, "run", fake_run), \
                mock.patch.object(hm.time, "time", return_value=NOW):
            hm.main([collector, "--textfile-dir", out])
            return Path(out, f"host-{collector}.prom").read_text()

    def check(self, collector):
        actual = self.run_collector(collector)
        expected = EXPECTED / f"host-{collector}.prom"
        if os.environ.get("UPDATE_EXPECTED"):
            expected.parent.mkdir(exist_ok=True)
            expected.write_text(actual)
        self.assertEqual(expected.read_text(), actual)

    def test_zfs(self):
        self.check("zfs")

    def test_units(self):
        self.check("units")

    def test_smart(self):
        self.check("smart")

    def test_bootc(self):
        self.check("bootc")


class Behaviour(unittest.TestCase):
    def test_label_values_are_escaped(self):
        self.assertEqual(hm.metric("m", {"a": 'x"y\\z\n'}), 'm{a="x\\"y\\\\z\\n"} 1')

    def test_failed_collector_keeps_previous_file(self):
        def failing_run(*cmd, check=True):
            raise subprocess.CalledProcessError(1, cmd)

        with tempfile.TemporaryDirectory() as out:
            prom = Path(out, "host-zfs.prom")
            prom.write_text("previous\n")
            with mock.patch.object(hm, "run", failing_run), self.assertRaises(subprocess.CalledProcessError):
                hm.main(["zfs", "--textfile-dir", out])
            self.assertEqual(prom.read_text(), "previous\n")
            self.assertEqual(os.listdir(out), ["host-zfs.prom"])

    def test_disk_in_standby_reports_nothing_else(self):
        report = {"smartctl": {"messages": [{"string": "Device is in SLEEP mode, exit(2)"}]}}
        self.assertEqual(hm.parse_smart_device("sdb", "sat", report), ['smart_device_standby{device="sdb"} 1'])

    def test_unparseable_disk_is_unreadable(self):
        with mock.patch.object(hm, "run", side_effect=lambda *c, check=True:
                               '{"devices":[{"name":"/dev/sda","type":"sat"}]}' if "--scan" in c else "not json"):
            lines = hm.collect_smart(NOW)
        self.assertIn('smart_device_readable{device="sda"} 0', lines)

    def test_pool_never_scanned(self):
        lines = hm.parse_zfs({"pools": {"new": {"state": "ONLINE", "vdevs": {}}}}, "", NOW)
        self.assertFalse([line for line in lines if line.startswith("zfs_scan_")])

    def test_nanosecond_timestamps(self):
        self.assertEqual(hm.parse_rfc3339("2026-10-12T01:02:03.123456789Z"), 1791766923)
        self.assertEqual(hm.parse_rfc3339("2026-10-12T14:02:03+13:00"), 1791766923)


if __name__ == "__main__":
    unittest.main()
