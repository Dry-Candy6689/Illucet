#!/usr/bin/env python3
"""Time bundled desktop yt-dlp against one authorized simulator benchmark log.

Only public video IDs, exact format IDs, byte counts and timings are saved. Signed
transport URLs stay in memory. Invoke separately from offline verification.
"""
import argparse
import json
from pathlib import Path
import re
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Vendor/PythonPackages"))
from yt_dlp import YoutubeDL
from yt_dlp.version import __version__


class QuietLogger:
    def debug(self, message):
        pass

    def warning(self, message):
        pass

    def error(self, message):
        pass  # Raw upstream messages can contain signed transport URLs.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native_log", type=Path)
    parser.add_argument("--node", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    match = re.search(r"ILLUCET_BENCHMARK (\{[^\n]+\})", args.native_log.read_text())
    if not match:
        parser.error("native log has no completed benchmark record")
    native = json.loads(match[1])
    if __version__ != native["ytDLPVersion"]:
        parser.error("desktop and simulator yt-dlp versions differ")
    if not re.fullmatch(r"[A-Za-z0-9_-]{11}", native["videoID"]):
        parser.error("invalid public video ID")
    results = []
    with tempfile.TemporaryDirectory(prefix="illucet-ytdlp-benchmark-") as directory:
        options = {
            "logger": QuietLogger(), "quiet": True, "no_warnings": True,
            "noprogress": True, "cachedir": False, "noplaylist": True,
            "geo_bypass": False, "proxy": "", "socket_timeout": 15,
            "retries": 1, "fragment_retries": 0, "extractor_retries": 1,
            "skip_unavailable_fragments": False,
            "js_runtimes": {"node": {"path": str(args.node)}},
            "remote_components": set(), "fixup": "never",
            "outtmpl": str(Path(directory) / "%(id)s.%(format_id)s.%(ext)s"),
        }
        started = time.monotonic()
        with YoutubeDL(options) as ydl:
            info = ydl.extract_info("https://www.youtube.com/watch?v=" + native["videoID"], download=False)
            extracted = time.monotonic()
            for fact in native["formats"]:
                candidates = [f for f in info["formats"] if f["format_id"] == fact["id"] and f["protocol"] == fact["protocol"]]
                if len(candidates) != 1:
                    raise RuntimeError("exact selected format unavailable")
                stream = {**info, **candidates[0]}
                # Download each selected source independently; no desktop FFmpeg merge
                # is included in the transfer comparison.
                stream.pop("requested_formats", None)
                stream.pop("requested_downloads", None)
                source_start = time.monotonic()
                ydl.process_info(stream)
                elapsed = time.monotonic() - source_start
                output = Path(ydl.prepare_filename(stream))
                if not output.is_file() or output.stat().st_size <= 0:
                    raise RuntimeError("download did not produce a nonempty regular file")
                results.append({"id": fact["id"], "protocol": fact["protocol"],
                    "seconds": elapsed, "bytes": output.stat().st_size})
        total = time.monotonic() - started
    if all(f["protocol"] in {"http", "https"} for f in native["formats"]):
        if sum(r["bytes"] for r in results) != native["downloadedBytes"]:
            raise RuntimeError("source byte totals differ between native and yt-dlp")
    transfer = sum(r["seconds"] for r in results)
    native_transfer = sum(seconds for stage, seconds in native["stages"].items() if stage.startswith("Downloading "))
    report = {"native": native, "ytDLP": {"version": __version__, "platform": "macOS",
        "extractionSeconds": extracted - started, "transferSeconds": transfer,
        "totalWithoutMergeSeconds": total, "sources": results},
        "nativeTransferSeconds": native_transfer,
        "nativeToYtdlpTransferRatio": native_transfer / transfer}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, sort_keys=True), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Do not persist upstream exception text: it may contain transport secrets.
        print("Benchmark failed: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
