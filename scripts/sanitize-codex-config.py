#!/usr/bin/env python3
"""Sanitize Codex config.toml for container execution.

Rewrites localhost references to host.docker.internal and strips
[projects.*] sections that contain host-specific paths.

Usage: sanitize-codex-config.py <input> <output>
"""
import re
import sys


def sanitize(input_path: str, output_path: str) -> None:
    try:
        with open(input_path) as f:
            content = f.read()
    except IOError as e:
        print(f"[sanitize] ERROR: Failed to read {input_path}: {e}", file=sys.stderr)
        sys.exit(1)

    content = re.sub(r"localhost|127\.0\.0\.1", "host.docker.internal", content)
    content = re.sub(r"\[projects\.[^\]]*\]\n(?:[^\[]*\n)*", "", content)

    try:
        with open(output_path, "w") as f:
            f.write(content)
    except IOError as e:
        print(f"[sanitize] ERROR: Failed to write {output_path}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input> <output>", file=sys.stderr)
        sys.exit(1)
    sanitize(sys.argv[1], sys.argv[2])
