#!/usr/bin/env python3
# SPDX-License-Identifier: EPL-2.0
"""Build every image of the Java test cloud v5.3.0 from the primary source Eclipse-Arrowhead-java (current main).

  build.py [--only db|app|core] [--force] [--no-cache] [FOLDER ...]

Support images come from the build sections of each primary folder's compose.yaml (application images run the folder's
`mvn clean verify`); core images from ah5-core-java-spring/<module>/docker/Dockerfile-* with a context holding only the
common and core sources. Existing tags are skipped unless --force. Results: generator/build-results.json.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import time

from generate import CORE, PRIMARY, REGISTRY, SUPPORT, TAG, image, render

HERE = pathlib.Path(__file__).resolve().parent


def primary_version() -> str:
    """The primary core's <revision>: the version in the core jar names, which the core Dockerfiles take as AH_VERSION."""
    m = re.search(r"<revision>([^<]+)</revision>", (PRIMARY / "ah5-core-java-spring/pom.xml").read_text())
    if not m:
        raise SystemExit("no <revision> in the primary ah5-core-java-spring/pom.xml")
    return m.group(1).strip()


def exists(tag: str) -> bool:
    return subprocess.run(["docker", "image", "inspect", tag], capture_output=True).returncode == 0


def build(tag: str, context: pathlib.Path, dockerfile: pathlib.Path | None, args: argparse.Namespace, log: pathlib.Path,
          extra: list[str] | None = None) -> dict:
    if exists(tag) and not args.force:
        return {"image": tag, "result": "EXISTS"}
    cmd = ["docker", "build", "--progress=plain", "-t", tag] + (["--no-cache"] if args.no_cache else []) + (extra or [])
    if dockerfile:
        cmd += ["-f", str(dockerfile)]
    start = time.time()
    with log.open("w") as out:
        code = subprocess.run(cmd + [str(context)], stdout=out, stderr=subprocess.STDOUT).returncode
    tests = [l.split("] ", 1)[-1] for l in log.read_text().splitlines() if "Tests run:" in l and " in " not in l]
    return {"image": tag, "result": "PASS" if code == 0 else "FAIL", "seconds": round(time.time() - start),
            "tests": tests[-1] if tests else None, "log": str(log)}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["db", "app", "core"])
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--no-cache", action="store_true")
    ap.add_argument("folders", nargs="*")
    args = ap.parse_args()
    logs = HERE / "build-logs"
    logs.mkdir(exist_ok=True)
    results_file = HERE / "build-results.json"
    results = json.loads(results_file.read_text()) if results_file.exists() else {}
    if args.only in (None, "db", "app"):
        for folder in args.folders or SUPPORT:
            for svc, s in render(PRIMARY / folder)["services"].items():
                kind = "db" if svc.endswith(("-db", "-graphdb")) else "app"
                if args.only and args.only != kind or "build" not in s:
                    continue
                tag = image(folder, svc, None)
                b = s["build"]
                r = build(tag, pathlib.Path(b["context"]), pathlib.Path(b["context"]) / b.get("dockerfile", "Dockerfile"),
                          args, logs / f"{tag.split('/')[-1].replace(':', '_')}.log")
                results[tag] = r | {"source": str(PRIMARY / folder)}
                print(r["result"], tag, r.get("tests") or "", flush=True)
                results_file.write_text(json.dumps(results, indent=2) + "\n")
    if args.only in (None, "core") and not args.folders:
        with tempfile.TemporaryDirectory(prefix="ah-core-context-") as tmp:
            for part in ("ah5-common-java-spring", "ah5-core-java-spring"):
                shutil.copytree(PRIMARY / part, pathlib.Path(tmp) / part, ignore=shutil.ignore_patterns("target", "*.log"))
            for module in sorted(set(CORE.values())):
                db = f"{REGISTRY}/{module}-db:{TAG}"
                r = build(db, pathlib.Path(tmp) / "ah5-core-java-spring", HERE / "core-db/Dockerfile", args,
                          logs / f"{module}-db.log", ["--build-arg", f"MODULE={module}"])
                results[db] = r | {"source": str(PRIMARY / "ah5-core-java-spring" / module / "src/main/resources/database")}
                print(r["result"], db, flush=True)
                dockerfile = next(p for p in (pathlib.Path(tmp) / "ah5-core-java-spring" / module / "docker").glob("Dockerfile-*")
                                  if not p.name.endswith("-DB"))
                native = f"{REGISTRY}/{module}-java-native:{TAG}"
                r = build(native, pathlib.Path(tmp), dockerfile, args, logs / f"{module}-java-native.log", ["--build-arg", f"AH_VERSION={primary_version()}"])
                results[native] = r | {"source": str(PRIMARY / "ah5-core-java-spring" / module)}
                print(r["result"], native, flush=True)
                # read-only test-cloud adapter on top of the primary build
                tag = f"{REGISTRY}/{module}-java:{TAG}"
                r = build(tag, HERE / "core-adapter", None, argparse.Namespace(force=True, no_cache=False), logs / f"{module}-java.log",
                          ["--build-arg", f"BASE_IMAGE={native}"])
                results[tag] = r | {"source": str(PRIMARY / "ah5-core-java-spring" / module), "adapter": str(HERE / "core-adapter")}
                print(r["result"], tag, flush=True)
                results_file.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
