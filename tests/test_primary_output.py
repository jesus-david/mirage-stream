"""XWayland must use a reachable output both locally and during streaming."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


PROFILE = Path(__file__).resolve().parent.parent / "profiles/hyprland-headless"


class PrimaryOutputSelection(unittest.TestCase):
    def run_selector(self, monitors, requested=None, xrandr_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, body in {
                "hyprctl": 'printf "%s\\n" "$MONITORS_JSON"',
                "xrandr": 'printf "%s\\n" "$@"; exit "$XRANDR_EXIT"',
            }.items():
                executable = root / name
                executable.write_text("#!/bin/bash\n" + body + "\n")
                executable.chmod(0o755)
            environment = dict(os.environ, PATH=f"{root}:/usr/bin:/bin",
                               MONITORS_JSON=json.dumps(monitors),
                               XRANDR_EXIT=str(xrandr_exit))
            return subprocess.run(
                ["bash", str(PROFILE / "set-primary-output.sh.in")]
                + ([requested] if requested else []),
                env=environment, capture_output=True, text=True, timeout=5,
            )

    def test_local_output_wins_even_when_mirage_is_focused_and_first(self):
        result = self.run_selector([
            {"name": "MIRAGE", "focused": True},
            {"name": "DP-local", "focused": False},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["--output", "DP-local", "--primary"])

    def test_focused_physical_output_wins_over_other_physical_outputs(self):
        result = self.run_selector([
            {"name": "HDMI-local", "focused": False},
            {"name": "DP-local", "focused": True},
        ])
        self.assertEqual(result.stdout.splitlines(), ["--output", "DP-local", "--primary"])

    def test_stream_uses_mirage(self):
        monitors = [{"name": "DP-local", "focused": True}, {"name": "MIRAGE"}]
        result = self.run_selector(monitors, requested="MIRAGE")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["--output", "MIRAGE", "--primary"])

    def test_headless_only_session_uses_its_only_output(self):
        result = self.run_selector([{"name": "MIRAGE", "focused": True}])
        self.assertEqual(result.stdout.splitlines(), ["--output", "MIRAGE", "--primary"])

    def test_no_output_fails_without_calling_xrandr(self):
        result = self.run_selector([])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_xrandr_failure_is_reported_to_the_caller(self):
        result = self.run_selector([{"name": "DP-local"}], xrandr_exit=1)
        self.assertNotEqual(result.returncode, 0)

    def test_all_lifecycle_hooks_call_the_selector_without_aborting_streaming(self):
        for name in ["stream-start", "stream-stop", "hyprland-headless-session"]:
            with self.subTest(script=name):
                script = (PROFILE / f"{name}.sh.in").read_text()
                call = next(line for line in script.splitlines() if '/set-primary-output.sh"' in line)
                self.assertIn("|| log ", call)
                self.assertEqual('"$virtual_output"' in call, name == "stream-start")
