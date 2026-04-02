#!/usr/bin/env python3
"""Build and push the lbm-eval-oss Docker image to Amazon ECR."""

import argparse
import json
import os
import subprocess
from pathlib import Path


def run_command(command, *, cwd=None, input_text=None, check=True, env=None):
    print(f"+ {' '.join(command)}")
    subprocess.run(
        command,
        check=check,
        cwd=cwd,
        text=True,
        input=input_text,
        env=env,
    )


def get_account_id(region, profile):
    env = os.environ.copy()
    env["AWS_PROFILE"] = profile
    completed = subprocess.run(
        [
            "aws",
            "--region",
            region,
            "--profile",
            profile,
            "sts",
            "get-caller-identity",
        ],
        check=True,
        capture_output=True,
        text=True,
        env=env,
    )
    data = json.loads(completed.stdout)
    return data["Account"]


def ensure_ecr_repository(region, profile, repo_name):
    env = os.environ.copy()
    env["AWS_PROFILE"] = profile
    describe = subprocess.run(
        [
            "aws",
            "--region",
            region,
            "--profile",
            profile,
            "ecr",
            "describe-repositories",
            "--repository-names",
            repo_name,
        ],
        env=env,
        text=True,
        capture_output=True,
    )
    if describe.returncode == 0:
        return
    run_command(
        [
            "aws",
            "--region",
            region,
            "--profile",
            profile,
            "ecr",
            "create-repository",
            "--repository-name",
            repo_name,
        ],
    )


def login_to_ecr(region, profile, registry):
    env = os.environ.copy()
    env["AWS_PROFILE"] = profile
    password_proc = subprocess.run(
        [
            "aws",
            "ecr",
            "get-login-password",
            "--region",
            region,
            "--profile",
            profile,
        ],
        check=True,
        capture_output=True,
        text=True,
        env=env,
    )
    run_command(
        ["docker", "login", "--username", "AWS", "--password-stdin", registry],
        input_text=password_proc.stdout,
    )


def build_and_push(args):
    repo_root = Path(args.repo_root).resolve()
    dockerfile = repo_root / "docker" / "Dockerfile"
    local_tag = f"{args.repository}:{args.tag}"
    account_id = get_account_id(args.region, args.profile)
    registry = f"{account_id}.dkr.ecr.{args.region}.amazonaws.com"
    remote_tag = f"{registry}/{args.repository}:{args.tag}"

    # Ensure policy_interfaces is present
    policy_dir = repo_root / "docker" / "policy_interfaces"
    if not policy_dir.exists():
        print("Cloning policy_interfaces...")
        run_command(
            [
                "git",
                "clone",
                "--depth",
                "1",
                "git@github.shared-services.aws.tri.global:robotics/policy_interfaces.git",
                str(policy_dir),
            ],
        )

    ensure_ecr_repository(args.region, args.profile, args.repository)
    login_to_ecr(args.region, args.profile, registry)

    build_env = os.environ.copy()
    build_env.setdefault("DOCKER_BUILDKIT", "1")
    build_cmd = [
        "docker",
        "build",
        "--progress=plain",
        "-f",
        str(dockerfile),
        "--build-arg",
        f"UID={args.uid}",
        "--build-arg",
        f"GID={args.gid}",
        "--build-arg",
        f"LBM_EVAL_VERSION={args.lbm_eval_version}",
        "-t",
        local_tag,
    ]
    if args.no_cache:
        build_cmd.append("--no-cache")
    build_cmd.append(".")
    run_command(build_cmd, cwd=repo_root, env=build_env)

    run_command(["docker", "tag", local_tag, remote_tag])
    run_command(["docker", "push", remote_tag])
    print(f"\nPushed image: {remote_tag}")
    return remote_tag


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        default=Path(__file__).resolve().parents[1],
        type=Path,
        help="Path to the repository root (default: %(default)s)",
    )
    parser.add_argument(
        "--repository",
        default="lbm-eval-oss",
        help="ECR repository name (default: %(default)s)",
    )
    parser.add_argument(
        "--tag",
        default="latest",
        help="Image tag (default: %(default)s)",
    )
    parser.add_argument(
        "--region",
        default="us-east-1",
        help="AWS region (default: %(default)s)",
    )
    parser.add_argument(
        "--profile",
        default="default",
        help="AWS profile (default: %(default)s)",
    )
    parser.add_argument(
        "--uid",
        type=int,
        default=os.getuid(),
        help="UID for docker build (default: current user)",
    )
    parser.add_argument(
        "--gid",
        type=int,
        default=os.getgid(),
        help="GID for docker build (default: current group)",
    )
    parser.add_argument(
        "--lbm-eval-version",
        default="1.1.0",
        dest="lbm_eval_version",
        help="Version for asset wheels (default: %(default)s)",
    )
    parser.add_argument(
        "--no-cache",
        action="store_true",
        help="Build without Docker cache",
    )
    parser.add_argument(
        "--push-only",
        action="store_true",
        help="Skip build, just tag and push an existing local image",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    if args.push_only:
        local_tag = f"{args.repository}:{args.tag}"
        account_id = get_account_id(args.region, args.profile)
        registry = f"{account_id}.dkr.ecr.{args.region}.amazonaws.com"
        remote_tag = f"{registry}/{args.repository}:{args.tag}"
        ensure_ecr_repository(args.region, args.profile, args.repository)
        login_to_ecr(args.region, args.profile, registry)
        run_command(["docker", "tag", local_tag, remote_tag])
        run_command(["docker", "push", remote_tag])
        print(f"\nPushed image: {remote_tag}")
    else:
        build_and_push(args)


if __name__ == "__main__":
    main()
