#!/usr/bin/env python3
"""
Local development server for the Ozone Dashboard.
Serves static files AND provides an API endpoint to trigger the R pipeline.

Usage:
    cd web-dashboard
    python3 dev_server.py

Then open http://localhost:8080 in your browser.
"""

import http.server
import json
import os
import re
import subprocess
import tempfile
import threading
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

PORT = 8080
PROJECT_ROOT = Path(__file__).resolve().parent.parent
WEB_DIR = Path(__file__).resolve().parent

# Track sync state
sync_state = {"running": False, "last_result": None, "log": ""}


class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_DIR), **kwargs)

    def end_headers(self):
        # SimpleHTTPRequestHandler sends Last-Modified but no Cache-Control, which
        # lets the browser apply *heuristic* freshness (roughly 10% of the file's
        # age). For data/ JSON that was last written weeks ago, that means the
        # browser will happily serve its cached copy for days without ever
        # revalidating -- so running a sync appeared to change nothing. Force
        # revalidation on every request; this is a dev server, correctness beats
        # the handful of bytes saved.
        self.send_header("Cache-Control", "no-store, must-revalidate")
        super().end_headers()

    def do_POST(self):
        if self.path == "/api/sync":
            self.handle_sync()
        elif self.path.startswith("/api/retrain/"):
            self.handle_retrain()
        else:
            self.send_error(404)

    def do_GET(self):
        if self.path == "/api/sync/status":
            self.handle_sync_status()
        elif self.path.startswith("/api/realtime/"):
            self.handle_realtime()
        else:
            super().do_GET()

    def handle_sync(self):
        if sync_state["running"]:
            self.send_json(200, {"status": "already_running", "message": "Sync is already in progress."})
            return

        sync_state["running"] = True
        sync_state["log"] = ""
        sync_state["last_result"] = None

        thread = threading.Thread(target=run_sync_pipeline, daemon=True)
        thread.start()

        self.send_json(200, {"status": "started", "message": "Pipeline started. Poll /api/sync/status for progress."})

    def handle_sync_status(self):
        self.send_json(200, {
            "running": sync_state["running"],
            "last_result": sync_state["last_result"],
            "log": sync_state["log"],
        })

    def send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_retrain(self):
        """Retrain model for a specific site — same as clicking Retrain in app.R."""
        site_name = self.path.split("/api/retrain/")[1].replace("%20", " ")
        log_file = WEB_DIR / "sync.log"

        try:
            with open(log_file, "a") as lf:
                lf.write(f"\n--- Retrain: {site_name} ---\n")
                proc = subprocess.Popen(
                    ["Rscript", "-e",
                     f'source("Ozone_Model_Training.R"); train_site_model("{site_name}")'],
                    stdout=lf, stderr=subprocess.STDOUT,
                    cwd=str(PROJECT_ROOT),
                )
                proc.wait(timeout=300)

            # Re-export JSON so dashboard picks up new model
            subprocess.run(
                ["Rscript", str(WEB_DIR / "export_json.R")],
                capture_output=True, cwd=str(PROJECT_ROOT), timeout=120
            )
            self.send_json(200, {"status": "complete", "site": site_name})
        except Exception as e:
            self.send_json(500, {"status": "error", "message": str(e)})

    def handle_realtime(self):
        """Fetch latest hourly O3 from AirNow S3 — same logic as get_latest_o3() in app.R."""
        aqs_id = self.path.split("/api/realtime/")[1]
        clean_aqs = aqs_id.replace("-", "")
        now_utc = datetime.now(timezone.utc)

        for offset in range(-1, 7):
            check_time = now_utc - timedelta(hours=offset)
            y_str = check_time.strftime("%Y")
            ymd_str = check_time.strftime("%Y%m%d")
            h_str = check_time.strftime("%H")
            url = f"https://s3-us-west-1.amazonaws.com/files.airnowtech.org/airnow/{y_str}/{ymd_str}/HourlyData_{ymd_str}{h_str}.dat"

            try:
                with urllib.request.urlopen(url, timeout=10) as resp:
                    data = resp.read().decode("utf-8", errors="ignore")
                    for line in data.split("\n"):
                        parts = line.split("|")
                        if len(parts) >= 8 and parts[2].strip() == clean_aqs and parts[5].strip() == "OZONE":
                            val_ppm = float(parts[7].strip()) / 1000
                            self.send_json(200, {"value": val_ppm, "time": f"{ymd_str} {h_str}:00 UTC"})
                            return
            except Exception:
                continue

        self.send_json(200, {"value": None, "time": None})

    def log_message(self, format, *args):
        # Quieter logs — only show non-200 or API calls
        if args and (str(args[1]) != "200" or "/api/" in str(args[0])):
            super().log_message(format, *args)


def run_sync_pipeline():
    """
    Run the full R pipeline, identical to what app.R's master sync does:
      1. Ozone_Master_Sync.R — data fetch (AQS/AirNow O3 + ASOS weather),
         gap-fill missing days, retrain Random Forest models, generate
         tomorrow's forecast + backfill history with observed values
      2. export_json.R — convert CSVs + .rds models to JSON for dashboard

    This is the same as clicking "Sync & Refresh Ecosystem" in the Shiny app.
    """
    steps = [
        ("Master Sync (Data + Models + Forecasts)", [
            "Rscript", str(PROJECT_ROOT / "Ozone_Master_Sync.R")
        ]),
        ("JSON Export for Dashboard", [
            "Rscript", str(WEB_DIR / "export_json.R")
        ]),
    ]

    sync_state["log"] = ""
    log_file = WEB_DIR / "sync.log"

    for step_name, cmd in steps:
        sync_state["log"] = f"Running: {step_name}..."
        try:
            with open(log_file, "a") as lf:
                lf.write(f"\n--- {step_name} ---\n")
                proc = subprocess.Popen(
                    cmd,
                    stdout=lf, stderr=subprocess.STDOUT,
                    cwd=str(PROJECT_ROOT),
                )
                proc.wait(timeout=600)
                if proc.returncode != 0:
                    sync_state["log"] = f"[WARN] {step_name} exited with code {proc.returncode}"
        except subprocess.TimeoutExpired:
            proc.kill()
            sync_state["log"] = f"[ERROR] {step_name} timed out after 10 minutes"
        except FileNotFoundError:
            sync_state["log"] = "[ERROR] Rscript not found. Is R installed and on PATH?"
            break

    sync_state["running"] = False
    sync_state["last_result"] = "complete"
    sync_state["log"] = "Sync complete! Dashboard refreshing..."

    with open(log_file, "a") as lf:
        lf.write("\n--- Pipeline Complete ---\n")


if __name__ == "__main__":
    import socket

    # Try preferred port, fall back to next available
    port = PORT
    for attempt_port in range(PORT, PORT + 10):
        try:
            test_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            test_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            test_sock.bind(("", attempt_port))
            test_sock.close()
            port = attempt_port
            break
        except OSError:
            continue

    print(f"Ozone Dashboard Dev Server")
    print(f"  Static files: {WEB_DIR}")
    print(f"  R project:    {PROJECT_ROOT}")
    print(f"  Open:         http://localhost:{port}")
    print(f"  Sync API:     POST http://localhost:{port}/api/sync")
    print()

    server = http.server.HTTPServer(("", port), DashboardHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()
