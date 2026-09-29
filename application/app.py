#!/usr/bin/python3
"""Tiny web UI for the LXC appliance POC."""

from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import re
import socket
import subprocess
import tempfile
from urllib.request import Request, urlopen

APP_DIR = Path(__file__).resolve().parent
CONFIG = Path("/etc/appliance/appliance.conf")
PUBLIC_KEY = Path("/usr/lib/appliance-bootstrap/release.pub")
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


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


def version_tuple(version: str) -> tuple[int, int, int]:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("invalid version")
    return tuple(map(int, version.split(".")))


def config_value(name: str) -> str:
    prefix = f"{name}="
    for line in CONFIG.read_text(encoding="utf-8").splitlines():
        if line.startswith(prefix):
            return line[len(prefix):].strip().strip("'\"")
    raise ValueError(f"missing {name}")


def download(url: str, limit: int) -> bytes:
    request = Request(url, headers={"User-Agent": "LXC-Appliance-Update-Check"})
    with urlopen(request, timeout=10) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("download too large")
    return data


def latest_release() -> str:
    base_url = config_value("RELEASE_BASE_URL").rstrip("/")
    manifest = download(f"{base_url}/release.json", 65536)
    signature = download(f"{base_url}/release.json.sig", 8192)
    with tempfile.TemporaryDirectory(prefix="appliance-update-") as workdir:
        manifest_path = Path(workdir) / "release.json"
        signature_path = Path(workdir) / "release.json.sig"
        manifest_path.write_bytes(manifest)
        signature_path.write_bytes(signature)
        subprocess.run(
            ["minisign", "-Vm", str(manifest_path), "-x", str(signature_path), "-p", str(PUBLIC_KEY)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=5,
        )
    release = json.loads(manifest)
    if (
        set(release) != {"schema", "channel", "version", "filename", "sha256", "size"}
        or release["schema"] != 1
        or release["channel"] != "stable"
        or release["filename"] != f"appliance-app-{release['version']}.tar.gz"
    ):
        raise ValueError("invalid manifest")
    version_tuple(release["version"])
    return release["version"]


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

    def send_json(self, status: int, value: dict[str, object]) -> None:
        self.send_text(status, json.dumps(value, ensure_ascii=False) + "\n", "application/json")

    def do_GET(self) -> None:
        version = read_text(APP_DIR / "VERSION", "unknown")
        if self.path == "/health":
            self.send_text(200, "OK\n")
            return
        if self.path == "/version":
            self.send_text(200, f"{version}\n")
            return
        if self.path == "/check-update":
            try:
                latest = latest_release()
                self.send_json(200, {
                    "current": version,
                    "latest": latest,
                    "update_available": version_tuple(latest) > version_tuple(version),
                })
            except Exception as error:
                print(f"Update check failed: {error}", flush=True)
                self.send_json(502, {"error": "Impossible de vérifier les mises à jour"})
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
dl{{display:grid;grid-template-columns:1fr 1fr;gap:.7rem 1rem;margin:0 0 1.5rem}}dt{{color:#9ca3af}}dd{{margin:0;text-align:right}}
button{{font:inherit;color:#111827;background:#4ade80;border:0;border-radius:.4rem;padding:.65rem 1rem;cursor:pointer}}button:disabled{{opacity:.6;cursor:wait}}
#update-result{{min-height:1.5rem;margin:.75rem 0 0;color:#d1d5db}}
</style></head><body><main><h1>LXC APPLIANCE POC</h1><p class="status">OPERATIONAL — GITHUB UPDATE OK</p><dl>{rows}</dl>
<button id="check-update" type="button">Vérifier les mises à jour</button><p id="update-result" aria-live="polite"></p>
<script>const button=document.querySelector('#check-update'),result=document.querySelector('#update-result');button.onclick=async()=>{{button.disabled=true;result.textContent='Vérification…';try{{const response=await fetch('/check-update',{{cache:'no-store'}}),data=await response.json();if(!response.ok)throw new Error(data.error);result.textContent=data.update_available?`Version ${{data.latest}} disponible`:`À jour (${{data.current}})`}}catch(error){{result.textContent=error.message||'Vérification impossible'}}finally{{button.disabled=false}}}};</script>
</main></body></html>"""
        self.send_text(200, page, "text/html")

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.address_string()} - {fmt % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
