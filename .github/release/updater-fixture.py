#!/usr/bin/env python3
"""Serve an isolated signed update and a copy with a deliberately invalid signature."""
import faulthandler

faulthandler.dump_traceback_later(10, repeat=True)

import http.server
import os
from pathlib import Path
import socketserver
import sys

root = Path(sys.argv[1]).resolve()
os.chdir(root / "downloads")
# HTTPServer resolves its server name during binding. This loopback-only fixture
# needs no hostname lookup, which can stall on hosted macOS runners.
server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
(root / "port").write_text(str(server.server_address[1]))
faulthandler.cancel_dump_traceback_later()
server.serve_forever()
