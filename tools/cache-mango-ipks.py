#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = []
# ///
"""
cache-mango-ipks.py

Resolve and download the .ipk dependency closure for the Mango ExtRoot
package set (Lab 03 Step 7), so the install can run offline against
`opkg install /tmp/*.ipk` without needing internet on the Mango.

Why offline (the short version):

  - Students do not need to set up laptop NAT or upstream WAN cabling.
  - The Mango's drop firmware deliberately omits dnsmasq/firewall4
    (it is not a router); LAN-side DHCP and outbound NAT are not
    available, so opkg cannot reach the OpenWrt feeds without extra
    plumbing.
  - The bundle is reproducible: same commit + same day = same .ipk
    bytes on every student laptop. Pinned through opkg's
    `Filename:` index column.
  - Cross-platform: every laptop has curl/Python; per-OS NAT setup
    diverges across Linux, macOS, Windows.
  - Mirrors the real-world drop-device pattern: an operator stages
    binaries on the engagement platform, then sneakernets them onto
    the device.

Pipeline:

  1. Pull `Packages.gz` from three OpenWrt 23.05.3 feeds:
       packages/mipsel_24kc/{packages,base}/
       targets/ramips/mt76x8/packages/      (kernel modules live here)
  2. BFS the dependency graph rooted at WANT (default: tailscale,
     python3-light, fdisk). Stop at packages already present in the
     drop-mango NOR baseline (`ON_MANGO`).
  3. Download each missing .ipk to OUTPUT_DIR/ipks/.
  4. Write a manifest.json with versions and SHA256s for audit.

Defaults:

  - Output: courses/engagement-platform-labs/labs/output/ipks/
  - Want:   tailscale, python3-light, fdisk
  - Baseline: the canonical drop-mango PACKAGES set from
              build-drop-mango.sh.

Usage:

    cd courses/engagement-platform-labs
    uv run tools/cache-mango-ipks.py
    # ipks land in labs/output/ipks/
    # scp them to the Mango:
    #   scp -O labs/output/ipks/*.ipk root@192.168.1.1:/tmp/
    #   ssh root@192.168.1.1 'opkg install /tmp/*.ipk'

Override:

    uv run tools/cache-mango-ipks.py --want tailscale,python3-light,htop
    uv run tools/cache-mango-ipks.py --output /tmp/my-bundle
    uv run tools/cache-mango-ipks.py --version 23.05.3
"""

import argparse
import gzip
import hashlib
import io
import json
import re
import sys
import urllib.request
from collections import deque
from pathlib import Path

OPENWRT_VERSION = "23.05.3"
ARCH = "mipsel_24kc"
TARGET = "ramips/mt76x8"

DEFAULT_WANT = ["tailscale", "python3-light", "fdisk"]
# iptables-nft is in the Lab 02 NOR baseline (see ON_MANGO below); the
# offline cache doesn't need to redundantly bundle it. Listed in ON_MANGO
# so dep-closure resolution skips it.

# Packages already present in the canonical drop-mango NOR baseline.
# Mirrors the PACKAGES list in build-drop-mango.sh; do not include
# negative entries (those are explicit removals, not "already present").
ON_MANGO = {
    "base-files", "busybox", "ca-bundle", "ca-certificates", "dropbear",
    "fstools", "libc", "libgcc", "libustream-mbedtls", "logd", "mtd",
    "netifd", "opkg", "uci", "uclient-fetch", "urandom-seed", "urngd",
    "block-mount", "kmod-usb-storage", "kmod-usb3", "kmod-fs-ext4",
    "e2fsprogs", "curl", "jsonfilter", "tcpdump-mini",
    "iptables-nft",
    # Common transitive deps that ride along in the base build:
    "libpthread", "libssl1.1", "libcrypto1.1", "librt",
    "libblkid1", "libuuid1", "libsmartcols1", "libfdisk1",
    "kernel",
}


def feed_urls(version: str, arch: str, target: str):
    base = f"https://downloads.openwrt.org/releases/{version}"
    return {
        f"{base}/packages/{arch}/packages": f"{base}/packages/{arch}/packages",
        f"{base}/packages/{arch}/base":     f"{base}/packages/{arch}/base",
        f"{base}/targets/{target}/packages": f"{base}/targets/{target}/packages",
    }


def fetch_packages(feed_url: str) -> dict:
    """Fetch and parse the Packages.gz from a feed. Returns dict[package -> meta]."""
    url = feed_url + "/Packages.gz"
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = resp.read()
    text = gzip.decompress(data).decode("utf-8", errors="replace")

    idx = {}
    cur = {}
    for line in text.splitlines():
        if not line:
            if "Package" in cur:
                cur["Feed"] = feed_url
                idx[cur["Package"]] = cur
            cur = {}
            continue
        if line.startswith(" "):
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            cur[k.strip()] = v.strip()
    if "Package" in cur:
        cur["Feed"] = feed_url
        idx[cur["Package"]] = cur
    return idx


def resolve_closure(combined: dict, want: list, on_mango: set) -> list:
    """BFS the dependency graph; return list of package metadata records (in BFS order)."""
    queue = deque(want)
    needed = []
    seen = set()
    while queue:
        p = queue.popleft()
        if p in seen or p in on_mango:
            continue
        seen.add(p)
        info = combined.get(p)
        if info is None:
            # Virtual package, alternative provider, or already-on-system. Skip.
            continue
        needed.append(info)
        deps = info.get("Depends", "")
        for d in re.split(r",\s*", deps):
            d = d.split(" ")[0].strip()
            if d and d not in seen:
                queue.append(d)
    return needed


def download(url: str, dest: Path) -> bytes:
    """Download to dest and return the raw bytes (for hashing)."""
    with urllib.request.urlopen(url, timeout=60) as resp:
        data = resp.read()
    dest.write_bytes(data)
    return data


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Cache the .ipk dependency closure for offline opkg install on the Mango.",
    )
    ap.add_argument(
        "--want", default=",".join(DEFAULT_WANT),
        help=f"Comma-separated package roots (default: {','.join(DEFAULT_WANT)})",
    )
    ap.add_argument(
        "--output", default="labs/output/ipks",
        help="Output directory for the .ipk bundle (default: labs/output/ipks)",
    )
    ap.add_argument(
        "--version", default=OPENWRT_VERSION,
        help=f"OpenWrt version (default: {OPENWRT_VERSION})",
    )
    ap.add_argument(
        "--arch", default=ARCH,
        help=f"Package architecture (default: {ARCH})",
    )
    ap.add_argument(
        "--target", default=TARGET,
        help=f"Per-target feed (default: {TARGET})",
    )
    args = ap.parse_args()

    want = [w.strip() for w in args.want.split(",") if w.strip()]
    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=True)

    print(f"[cache] OpenWrt {args.version}, arch {args.arch}, target {args.target}")
    print(f"[cache] roots: {', '.join(want)}")
    print(f"[cache] output: {out}")

    print("[cache] fetching feed indexes...")
    combined = {}
    for feed in feed_urls(args.version, args.arch, args.target).values():
        try:
            idx = fetch_packages(feed)
            combined.update(idx)
            print(f"  ok   {feed}/Packages.gz  ({len(idx)} packages)")
        except Exception as exc:
            print(f"  FAIL {feed}/Packages.gz  ({exc})", file=sys.stderr)
            return 2

    print("[cache] resolving dependency closure...")
    needed = resolve_closure(combined, want, ON_MANGO)
    print(f"  {len(needed)} packages in closure (excluding NOR baseline)")
    for p in needed:
        print(f"    {p['Package']:25s}  {p.get('Version','?'):15s}  {p['Filename']}")

    print(f"[cache] downloading to {out}/ ...")
    manifest = {
        "openwrt_version": args.version,
        "arch": args.arch,
        "target": args.target,
        "want": want,
        "packages": [],
    }
    for p in needed:
        url = f"{p['Feed']}/{p['Filename']}"
        dest = out / p["Filename"]
        try:
            blob = download(url, dest)
        except Exception as exc:
            print(f"  FAIL {p['Filename']}  ({exc})", file=sys.stderr)
            return 3
        sha256 = hashlib.sha256(blob).hexdigest()
        manifest["packages"].append({
            "name": p["Package"],
            "version": p.get("Version", ""),
            "filename": p["Filename"],
            "size": len(blob),
            "sha256": sha256,
            "feed": p["Feed"],
        })
        print(f"  ok   {p['Filename']:60s} {len(blob):>10d}  {sha256[:12]}")

    manifest_path = out / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"[cache] manifest: {manifest_path}")
    print(f"[cache] done: {len(needed)} .ipk(s), {sum(p['size'] for p in manifest['packages']) // 1024} KB total")
    print()
    print("Next: scp the bundle to your Mango and install offline:")
    print(f"  scp -O {out}/*.ipk root@192.168.1.1:/tmp/")
    print("  ssh root@192.168.1.1 'opkg install /tmp/*.ipk'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
