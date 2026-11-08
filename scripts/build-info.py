#!/usr/bin/env python3
"""Emit a build-info.json provenance record for one kernel build.

Every field is supplied explicitly on the command line so a typo fails loudly
instead of silently landing in the JSON. The kernel source URL and revision are
derived from the repo manifest, which is the only place they are recorded
authoritatively (the source is fetched as tarballs, not as a git clone).

Usage:
    build-info.py --out build-info.json --manifest manifest.xml \
        --model OP15 --os-version A16 ... --zip artifacts/OP15_....zip
"""

import argparse
import hashlib
import json
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

SCHEMA_VERSION = 1


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_kernel_project(project):
    """Mirror the predicate in scripts/check-patches.sh.

    OnePlus manifests name the kernel tree inconsistently across branches, so
    accept any of: an explicit kernel_platform/common path, an android_kernel_*
    project (but not android_kernel_modules*), or a linkfile that materialises
    kernel_platform/common.
    """
    name = project.get("name") or ""
    path = project.get("path") or ""
    if path == "kernel_platform/common":
        return True
    if name.startswith("android_kernel_modules"):
        return False
    if name.startswith("android_kernel_"):
        return True
    return any(
        linkfile.get("dest") == "kernel_platform/common"
        for linkfile in project.findall("linkfile")
    )


def kernel_source_from_manifest(manifest_path):
    """Return (url, revision, project_path) for the kernel tree in a manifest."""
    root = ET.parse(manifest_path).getroot()
    remotes = {remote.get("name"): remote.get("fetch") for remote in root.findall("remote")}

    for project in root.findall("project"):
        if not is_kernel_project(project):
            continue
        fetch = (remotes.get(project.get("remote")) or "").rstrip("/")
        name = project.get("name") or ""
        url = f"{fetch}/{name}" if fetch else name
        return url, project.get("revision"), project.get("path")

    return None, None, None


def build_parser():
    parser = argparse.ArgumentParser(
        description="Write a build-info.json provenance record.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--out", required=True, help="path of the JSON file to write")
    parser.add_argument("--manifest", required=True, help="path to the repo manifest.xml")

    device = parser.add_argument_group("device")
    device.add_argument("--model", required=True)
    device.add_argument("--os-version", required=True)
    device.add_argument("--android-version", required=True)
    device.add_argument("--kernel-version", required=True)
    device.add_argument("--soc", default="")
    device.add_argument("--uname", default="")

    kernel = parser.add_argument_group("kernel")
    kernel.add_argument("--kernel-branch", default="")
    kernel.add_argument("--kernel-full-version", default="")
    kernel.add_argument("--image-sha256", default="")

    susfs = parser.add_argument_group("susfs")
    susfs.add_argument("--susfs-version", default="")
    susfs.add_argument("--susfs-ref", default="")
    susfs.add_argument("--susfs-commit", default="")

    ksu = parser.add_argument_group("ksu")
    ksu.add_argument("--ksu-type", default="")
    ksu.add_argument("--ksu-version", default="")
    ksu.add_argument("--ksu-ref", default="")
    ksu.add_argument("--ksu-commit", default="")

    toolchain = parser.add_argument_group("toolchain")
    toolchain.add_argument("--clang", default="")

    artifact = parser.add_argument_group("artifact")
    artifact.add_argument("--zip", default="", help="path to the AnyKernel3 zip")

    build = parser.add_argument_group("build")
    build.add_argument("--run-id", default="")
    build.add_argument("--run-attempt", default="")
    build.add_argument("--repository", default="")
    build.add_argument("--commit", default="")
    build.add_argument("--workflow", default="")

    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)

    if not os.path.isfile(args.manifest):
        print(f"error: manifest not found: {args.manifest}", file=sys.stderr)
        return 1

    kernel_url, kernel_ref, kernel_path = kernel_source_from_manifest(args.manifest)
    if not kernel_url:
        print(f"error: no kernel source project in {args.manifest}", file=sys.stderr)
        return 1

    artifact = {}
    if args.zip:
        if not os.path.isfile(args.zip):
            print(f"error: zip not found: {args.zip}", file=sys.stderr)
            return 1
        artifact = {
            "zip_name": os.path.basename(args.zip),
            "zip_sha256": sha256_file(args.zip),
            "zip_size": os.path.getsize(args.zip),
        }

    record = {
        "schema": SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "device": {
            "model": args.model,
            "os_version": args.os_version,
            "android_version": args.android_version,
            "kernel_version": args.kernel_version,
            "soc": args.soc,
            "uname": args.uname,
        },
        "kernel": {
            "source_url": kernel_url,
            "source_ref": kernel_ref,
            "source_path": kernel_path,
            "branch": args.kernel_branch,
            "full_version": args.kernel_full_version,
            "manifest": os.path.basename(args.manifest),
            "manifest_sha256": sha256_file(args.manifest),
            "image_sha256": args.image_sha256,
        },
        "susfs": {
            "enabled": bool(args.susfs_version or args.susfs_ref or args.susfs_commit),
            "version": args.susfs_version,
            "ref": args.susfs_ref,
            "commit": args.susfs_commit,
        },
        "ksu": {
            "type": args.ksu_type,
            "version": args.ksu_version,
            "ref": args.ksu_ref,
            "commit": args.ksu_commit,
        },
        "toolchain": {"clang": args.clang},
        "artifact": artifact,
        "build": {
            "run_id": args.run_id,
            "run_attempt": args.run_attempt,
            "repository": args.repository,
            "commit": args.commit,
            "workflow": args.workflow,
        },
    }

    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2, sort_keys=False)
        handle.write("\n")

    print(f"Wrote {args.out}")
    print(json.dumps(record, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
