#!/usr/bin/python3
"""Tiny web UI for the LXC appliance POC."""

from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import subprocess

APP_DIR = Path(__file__).resolve().parent


def read_text(path: Path, default: str) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return default


def container_ip() -> str:
    try:
        output = subprocess.check_output(
            ["ip", "-4", "-o", "addr", "show", "scope", "global"],
            text=True,
            timeout=2,
        )
        return output.split()[3].split("/", 1)[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        return "unavailable"


def uptime() -> str:
    try:
        seconds = int(float(Path("/proc/uptime").read_text().split()[0]))
    except (OSError, ValueError, IndexError):
        return "unavailable"
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes = seconds // 60
    return f"{days}d {hours}h {minutes}m" if days else f"{hours}h {minutes}m"


class Handler(BaseHTTPRequestHandler):
    server_version = "AppliancePOC/0.1"

    def send_text(self, status: int, body: str, content_type: str = "text/plain") -> None:
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", f"{content_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        version = read_text(APP_DIR / "VERSION", "unknown")
        if self.path == "/health":
            self.send_text(200, "OK\n")
            return
        if self.path == "/version":
            self.send_text(200, f"{version}\n")
            return
        if self.path != "/":
            self.send_text(404, "Not Found\n")
            return

        bootstrap = read_text(Path("/var/lib/appliance/bootstrap-version"), "development")
        values = {
            "Application version": version,
            "Bootstrap version": bootstrap,
            "Hostname": socket.gethostname(),
            "IP": container_ip(),
            "Uptime": uptime(),
            "Installation": "SUCCESS" if Path("/var/lib/appliance/installed").exists() else "IN PROGRESS",
        }
        rows = "".join(
            f"<dt>{escape(label)}</dt><dd>{escape(value)}</dd>"
            for label, value in values.items()
        )
        page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>LXC Appliance POC</title><style>
body{{font:16px system-ui,sans-serif;background:#111827;color:#e5e7eb;margin:0;display:grid;place-items:center;min-height:100vh}}
main{{width:min(34rem,calc(100% - 3rem));background:#1f2937;padding:2rem;border-radius:.75rem}}
h1{{font-size:1.45rem;margin:0 0 .5rem}} .status{{color:#4ade80;font-weight:700;margin:0 0 1.5rem}}
dl{{display:grid;grid-template-columns:1fr 1fr;gap:.7rem 1rem;margin:0}}dt{{color:#9ca3af}}dd{{margin:0;text-align:right}}
</style></head><body><main><h1>LXC APPLIANCE POC</h1><p class="status">OPERATIONAL — GITHUB UPDATE OK</p><dl>{rows}</dl></main></body></html>"""
        self.send_text(200, page, "text/html")

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.address_string()} - {fmt % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
