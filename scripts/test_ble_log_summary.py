"""Tests for ble_log_summary.py with synthetic log lines (made-up names, no real devices).

Run: python3 -m unittest discover -s scripts -p 'test_*.py'
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ble_log_summary as s  # noqa: E402

IOS_LOG = """\
2026-10-13T01:00:00Z BLE radio on
2026-10-13T01:00:01Z BLE found a Libre device rssi=-58 after_start_s=1.2
2026-10-13T01:00:02Z BLE link open role=central mtu=182
2026-10-13T01:00:03Z BLE verified Ana Phone key=ab12cd34 role=central mtu=182 after_s=0.9
2026-10-13T01:00:04Z BLE probe Ana Phone role=central mtu=182 bytes=4096 rtt_ms=512 Bps=8000
2026-10-13T01:05:04Z BLE probe Ana Phone role=central mtu=182 bytes=4096 rtt_ms=410 Bps=9990
2026-10-13T01:06:00Z MSG chat link=bluetooth hops=1
2026-10-13T01:06:10Z MSG chat link=bluetooth hops=2
2026-10-13T01:07:00Z MSG answer link=bluetooth hops=1 rtt_ms=3100 ai_ms=2500
2026-10-13T01:08:00Z MSG answer link=bluetooth hops=1 rtt_ms=2900 ai_ms=2400
2026-10-13T01:09:00Z MSG answer link=wifi hops=1 rtt_ms=2700 ai_ms=2600
"""

ANDROID_LOGCAT = """\
10-13 09:00:04.000  1234  1250 I LibreBLE: verified Ben Mac key=ef56ab78 role=CENTRAL mtu=247 after_s=1.5
10-13 09:00:05.000  1234  1250 I LibreBLE: probe Ben Mac role=CENTRAL mtu=247 bytes=4096 rtt_ms=300 Bps=13653
10-13 09:01:00.000  1234  1250 I LibreMesh: MSG answer link=bluetooth hops=1 rtt_ms=2800
"""


class ParseTests(unittest.TestCase):
    def test_ios_log(self):
        d = s.parse(IOS_LOG)
        self.assertEqual(d["probe_kbps"]["Ana Phone"], [8.0, 9.99])
        self.assertEqual(d["mtu"]["Ana Phone"], {182})
        self.assertEqual(d["verify_s"], [0.9])
        self.assertEqual(d["found_rssi"], [-58])
        self.assertEqual(d["rtt"][("bluetooth", 1)], [3100, 2900])
        self.assertEqual(d["ai"][("bluetooth", 1)], [2500, 2400])
        self.assertEqual(d["rtt"][("wifi", 1)], [2700])
        self.assertEqual(d["chats"][("bluetooth", 2)], 1)

    def test_android_logcat(self):
        d = s.parse(ANDROID_LOGCAT)
        self.assertEqual(d["probe_kbps"]["Ben Mac"], [13.653])
        self.assertEqual(d["verify_s"], [1.5])
        self.assertEqual(d["rtt"][("bluetooth", 1)], [2800])
        self.assertEqual(d["ai"][("bluetooth", 1)], [])

    def test_report_rows(self):
        text = s.report("ios.txt", s.parse(IOS_LOG))
        self.assertIn("| 4 KB probe to Ana Phone (KB/s, MTU 182) | n=2, median 9.0, range 8.0 to 10.0 |", text)
        self.assertIn("| @libre round trip, answer over bluetooth, 1 hop(s) (ms) | n=2, median 3000, range 2900 to 3100 |", text)
        self.assertIn("| Chats received over bluetooth, 2 hop(s) | 1 |", text)

    def test_since_drops_older_stamped_lines_only(self):
        d = s.parse(s.since(IOS_LOG + ANDROID_LOGCAT, "2026-10-13T01:06"))
        self.assertEqual(dict(d["probe_kbps"]), {"Ben Mac": [13.653]})   # iOS probes are older
        self.assertEqual(d["rtt"][("bluetooth", 1)], [3100, 2900, 2800])

    def test_empty_log(self):
        self.assertIn("no Libre Bluetooth lines found", s.report("x", s.parse("hello\n")))


if __name__ == "__main__":
    unittest.main()
