#!/usr/bin/env python3
# SPDX-License-Identifier: EPL-2.0
"""Prepare the Java test cloud to run the qualified release images instead of rebuilding them.

  use-release-images.py <manifest.json> <tag>

The manifest is Eclipse-Arrowhead-java/verification/release-<version>/manifest.json (release_manifest.py). For every
image of this cloud (generate.py's naming, arrowhead-java-v530/<folder>[-db|-graphdb|-docker-proxy]:<tag>):
  - support systems: the release image of the same folder and service is tagged, so the cloud runs exactly that image;
  - core systems: the release image (built from ah5-core-java-spring/<module>/docker/Dockerfile-*) is the base of the
    read-only test-cloud adapter (core-adapter/), as build.py does with its own core build;
  - core databases: the release's own core database images (ah5-core-java-spring/<module>/docker/Dockerfile-*-DB, MySQL
    8.4.13 since Eclipse-Arrowhead-java f1103ac9, the recipe of core-db/) are tagged; for a manifest of an earlier commit,
    whose core database images were the unusable upstream mysql:8.1 ones, core-db/Dockerfile is built from that commit.
Writes generator/release-images.json (cloud image -> release image and image IDs). Set TAG in generate.py to <tag>, then
`python3 generator/generate.py` and `./generator/deploy.sh up`.
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile

from generate import CORE, PRIMARY, REGISTRY

HERE = pathlib.Path(__file__).resolve().parent


def run(*cmd: str) -> str:
    r = subprocess.run(list(cmd), capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"{' '.join(cmd[:4])} failed: {r.stderr.strip()[-400:]}")
    return r.stdout.strip()


def image_id(ref: str) -> str:
    return run("docker", "image", "inspect", "-f", "{{.Id}}", ref)


def main() -> None:
    manifest, tag = json.loads(pathlib.Path(sys.argv[1]).read_text()), sys.argv[2]
    commit, version = manifest["commit"], manifest["release"]
    out = {"manifestCommit": commit, "release": version, "tag": tag, "images": {}}
    for e in manifest["images"]:
        if e["result"] != "PASS" or e["source"].startswith("ah5-core-java-spring") or e["source"] == "ah5-SoSConfigurator-java":
            continue
        service = e["service"]
        suffix = "-db" if service.endswith("-db") else "-graphdb" if service.endswith("-graphdb") else "-docker-proxy" if service == "docker-proxy" else ""
        target = f"{REGISTRY}/{e['source'].lower()}{suffix}:{tag}"
        if image_id(e["image"]) != e["imageId"]:
            raise SystemExit(f"{e['image']} is no longer the image of the manifest")
        run("docker", "tag", e["image"], target)
        out["images"][target] = {"from": e["image"], "imageId": e["imageId"], "how": "tagged"}
    with tempfile.TemporaryDirectory(prefix="ah-core-", dir=pathlib.Path.home()) as tmp:
        src = pathlib.Path(tmp)
        tar = src / "src.tar"
        tar.write_bytes(subprocess.run(["git", "-C", str(PRIMARY), "archive", "--format=tar", commit, "ah5-core-java-spring"], capture_output=True, check=True).stdout)
        with tarfile.open(tar) as t:
            t.extractall(src, filter="data")
        for module in sorted(set(CORE.values())):
            release = next(e for e in manifest["images"] if e["image"] == f"arrowhead-{module}:{version}")
            if image_id(release["image"]) != release["imageId"]:
                raise SystemExit(f"{release['image']} is no longer the image of the manifest")
            app = f"{REGISTRY}/{module}-java:{tag}"
            run("docker", "build", "-q", "-t", app, "--build-arg", f"BASE_IMAGE={release['image']}", str(HERE / "core-adapter"))
            out["images"][app] = {"from": release["image"], "imageId": image_id(app), "baseImageId": release["imageId"], "how": "core-adapter on the release image"}
            db = f"{REGISTRY}/{module}-db:{tag}"
            release_db = next(e for e in manifest["images"] if e["image"] == f"arrowhead-{module}-db:{version}")
            mysql84 = any(b.startswith("mysql:8.4") for b in release_db["baseImages"])
            if mysql84:
                if image_id(release_db["image"]) != release_db["imageId"]:
                    raise SystemExit(f"{release_db['image']} is no longer the image of the manifest")
                run("docker", "tag", release_db["image"], db)
                out["images"][db] = {"from": release_db["image"], "imageId": release_db["imageId"], "how": "tagged"}
            else:
                run("docker", "build", "-q", "-t", db, "--build-arg", f"MODULE={module}", "-f", str(HERE / "core-db/Dockerfile"), str(src / "ah5-core-java-spring"))
                out["images"][db] = {"from": f"core-db/Dockerfile, {module} at {commit[:8]}", "imageId": image_id(db), "how": "built from the manifest commit"}
            print("core", module, flush=True)
    (HERE / "release-images.json").write_text(json.dumps(out, indent=2) + "\n")
    print(len(out["images"]), "images ->", tag)


if __name__ == "__main__":
    main()
