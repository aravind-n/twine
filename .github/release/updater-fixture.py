#!/usr/bin/env python3
"""Serve an isolated signed update and a copy with a deliberately invalid signature."""
import http.server
import os
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
os.chdir(root / "downloads")
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
(root / "port").write_text(str(server.server_port))
server.serve_forever()
