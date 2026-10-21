#!/usr/bin/env python3
"""Compile and exercise the native launcher against an inert temporary app."""
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS LaunchServices")
class MacLaunchers(unittest.TestCase):
    def test_native_launch_and_persistence(self):
        root = Path(__file__).resolve().parents[2]
        source = root / "macos/ProxyLauncher"
        with tempfile.TemporaryDirectory(prefix="cipherrelay-launcher-build-") as directory, socket.socket() as listener:
            directory = Path(directory)
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            helper = directory / "ProxyLauncher"
            test = directory / "LauncherSmokeTests"
            for output, files in [
                (helper, ["LauncherConfiguration.swift", "main.swift"]),
                (test, ["LauncherConfiguration.swift", "LauncherStore.swift", "LauncherApplications.swift", "LauncherSmokeTests.swift"]),
            ]:
                subprocess.run(["xcrun", "swiftc", "-framework", "AppKit",
                                *[str(source / f) for f in files], "-o", str(output)], check=True, timeout=60)
            subprocess.run([str(test), str(helper), str(listener.getsockname()[1])], check=True, timeout=30)


if __name__ == "__main__":
    unittest.main()
