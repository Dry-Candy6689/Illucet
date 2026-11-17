#!/usr/bin/env python3
"""Build the pinned HTTP-only libaria2 and OpenSSL for iOS and Simulator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def build(if_needed=False):
    pin = json.loads((ROOT / "Config/Aria2.json").read_text())
    ssl = next(x for x in json.loads((ROOT / "Config/NativeSupportSources.json").read_text())
               if x["archive"].startswith("openssl-"))
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = subprocess.check_output(
        [str(ROOT / "Scripts/resolve-developer-dir.sh")], text=True).strip()
    env["ZERO_AR_DATE"] = "1"
    recipe = hashlib.sha256(Path(__file__).read_bytes() + json.dumps([pin, ssl], sort_keys=True).encode()).hexdigest()
    destination = ROOT / "Vendor/Frameworks/IllucetAria2.xcframework"
    receipt = destination / "Provenance.json"
    if if_needed and receipt.is_file() and json.loads(receipt.read_text()).get("recipeSHA256") == recipe:
        data = json.loads(receipt.read_text())
        if all((destination / name).is_file() and digest(destination / name) == sha
               for name, sha in data["libraries"].items()):
            print("Verified existing pinned aria2 runtime.", flush=True)
            return
    workspace = Path(env.get("ILLUCET_NATIVE_WORKSPACE", "/private/tmp/IllucetNativeBuild"))
    if not workspace.is_absolute():
        raise ValueError("Use an absolute native workspace")
    work = workspace / ("Aria2-" + pin["version"])
    work.mkdir(parents=True, exist_ok=True)
    lock = work / ".build-lock"
    lock.mkdir()
    try:
        downloads = ROOT / "Vendor/Downloads"
        downloads.mkdir(parents=True, exist_ok=True)
        for source in (pin["source"], ssl):
            archive = downloads / source["archive"]
            if not archive.exists():
                with urllib.request.urlopen(source["url"], timeout=60) as response:
                    payload = response.read()
                if hashlib.sha256(payload).hexdigest() != source["sha256"]:
                    raise ValueError("Native source digest mismatch")
                archive.write_bytes(payload)
            if digest(archive) != source["sha256"]:
                raise ValueError("Native source digest mismatch")
        arguments = ["xcodebuild", "-create-xcframework"]
        for sdk, arch, ssl_target in (("iphoneos", "arm64", "ios64-xcrun"),
                                      ("iphonesimulator", "arm64", "iossimulator-arm64-xcrun"),
                                      ("iphonesimulator", "x86_64", "iossimulator-x86_64-xcrun")):
            name = sdk + "-" + arch
            print("Building aria2 + OpenSSL: " + name, flush=True)
            stage = work / name
            if stage.exists():
                shutil.rmtree(stage)
            stage.mkdir()
            for source in (pin["source"], ssl):
                with tarfile.open(downloads / source["archive"]) as archive:
                    archive.extractall(stage, filter="data")
            ssl_source = stage / ssl["archive"].removesuffix(".tar.gz")
            aria_source = stage / ("aria2-" + pin["version"])
            sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], env=env, text=True).strip()
            target = arch + "-apple-ios" + pin["minimumIOS"] + ("-simulator" if sdk == "iphonesimulator" else "")
            flags = ("-target " + target + " -isysroot " + sdk_path + " -Os -fvisibility=hidden"
                     + " -ffile-prefix-map=" + str(work) + "=/illucet-native")
            prefix = stage / "openssl-prefix"
            with (work / (name + ".log")).open("w") as log:
                def run(args, cwd, extra=None):
                    subprocess.run(args, cwd=cwd, env=env | (extra or {}), stdout=log,
                                   stderr=subprocess.STDOUT, check=True)
                minimum = ("-mios-simulator-version-min=" if sdk == "iphonesimulator" else "-miphoneos-version-min=") + pin["minimumIOS"]
                run(["perl", "Configure", ssl_target, "--prefix=" + str(prefix), "--libdir=lib",
                     "no-shared", "no-tests", "no-module", "no-dso", minimum, "-Os", "-fvisibility=hidden",
                     "-ffile-prefix-map=" + str(work) + "=/illucet-native"], ssl_source)
                run(["make", "-j", "8", "build_libs"], ssl_source)
                run(["make", "install_dev"], ssl_source)
                aria_build = stage / "aria-build"
                aria_build.mkdir()
                compiler = subprocess.check_output(["xcrun", "--find", "clang"], env=env, text=True).strip()
                host = ("aarch64" if arch == "arm64" else "x86_64") + "-apple-darwin"
                extra = {"CC": compiler, "CXX": compiler + "++", "CFLAGS": flags,
                         "CXXFLAGS": flags + " -fvisibility-inlines-hidden", "LDFLAGS": flags,
                         "PKG_CONFIG_LIBDIR": str(prefix / "lib/pkgconfig"), "PKG_CONFIG_PATH": "",
                         "OPENSSL_CFLAGS": "-I" + str(prefix / "include"),
                         "OPENSSL_LIBS": "-L" + str(prefix / "lib") + " -lssl -lcrypto"}
                run([str(aria_source / "configure"), "--host=" + host,
                     "--build=" + subprocess.check_output([str(aria_source / "config.guess")], text=True).strip(),
                     "--enable-libaria2", "--enable-static", "--disable-shared", "--disable-bittorrent",
                     "--disable-metalink", "--disable-websocket", "--disable-nls", "--without-appletls",
                     "--without-wintls", "--without-gnutls", "--without-libnettle", "--without-libgmp",
                     "--without-libgcrypt", "--with-openssl", "--without-libssh2", "--without-sqlite3",
                     "--without-libcares", "--without-libuv", "--without-libxml2", "--without-libexpat",
                     "--without-libz"], aria_build, extra)
                run(["make", "-j", "8", "-C", "src", "libaria2.la"], aria_build, extra)
                library = stage / "libIllucetAria2.a"
                run(["xcrun", "libtool", "-static", "-o", str(library),
                     str(aria_build / "src/.libs/libaria2.a"), str(prefix / "lib/libssl.a"),
                     str(prefix / "lib/libcrypto.a")], stage)
                headers = stage / "headers/aria2"
                headers.mkdir(parents=True)
                shutil.copy2(aria_source / "src/includes/aria2/aria2.h", headers / "aria2.h")
                arguments += ["-library", str(library), "-headers", str(headers.parent)]
        # Apple requires one combined simulator slice when both architectures exist.
        simulator = work / "simulator"
        simulator.mkdir(exist_ok=True)
        subprocess.run(["xcrun", "lipo", "-create", str(work / "iphonesimulator-arm64/libIllucetAria2.a"),
                        str(work / "iphonesimulator-x86_64/libIllucetAria2.a"), "-output",
                        str(simulator / "libIllucetAria2.a")], env=env, check=True)
        arguments = arguments[:6] + ["-library", str(simulator / "libIllucetAria2.a"),
                                      "-headers", str(work / "iphonesimulator-arm64/headers")]
        output = work / "IllucetAria2.xcframework"
        if output.exists():
            shutil.rmtree(output)
        subprocess.run(arguments + ["-output", str(output)], env=env, check=True)
        libraries = {str(p.relative_to(output)): digest(p) for p in output.rglob("*.a")}
        (output / "Provenance.json").write_text(json.dumps({"version": pin["version"],
            "sourceSHA256": pin["source"]["sha256"], "openSSLSHA256": ssl["sha256"],
            "recipeSHA256": recipe, "libraries": libraries}, indent=2) + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(output, destination)
        print("Built pinned IllucetAria2.xcframework.", flush=True)
    finally:
        lock.rmdir()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--if-needed", action="store_true")
    build(parser.parse_args().if_needed)
