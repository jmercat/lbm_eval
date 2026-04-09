#!/usr/bin/env python3
"""
Build and push the lbm-eval-oss Docker image to Docker Hub.

Usage:
    python docker/publish_to_dockerhub.py                        # default tag: vla-foundry
    python docker/publish_to_dockerhub.py --tag my-tag           # custom tag
    python docker/publish_to_dockerhub.py --skip-build           # push only (image already built)
"""

import argparse
import subprocess
import sys

DOCKERHUB_REPO = "toyotaresearch/lbm-eval-oss"
LOCAL_IMAGE = "lbm-eval-oss"


def run(cmd: list[str]) -> None:
    print(f"+ {' '.join(cmd)}")
    subprocess.check_call(cmd)


def main() -> None:
    parser = argparse.ArgumentParser(description="Publish lbm-eval-oss to Docker Hub")
    parser.add_argument("--tag", default="vla-foundry", help="Image tag (default: vla-foundry)")
    parser.add_argument("--skip-build", action="store_true", help="Skip the build step")
    args = parser.parse_args()

    local_tag = f"{LOCAL_IMAGE}:{args.tag}"
    remote_tag = f"{DOCKERHUB_REPO}:{args.tag}"

    # Build
    if not args.skip_build:
        print(f"\n=== Building {local_tag} ===\n")
        run(["bash", "docker/build.sh", args.tag])

    # Tag for Docker Hub
    print(f"\n=== Tagging {local_tag} -> {remote_tag} ===\n")
    run(["docker", "tag", local_tag, remote_tag])

    # Push
    print(f"\n=== Pushing {remote_tag} ===\n")
    run(["docker", "push", remote_tag])

    print(f"\nDone. Image available at: docker.io/{remote_tag}")


if __name__ == "__main__":
    main()
