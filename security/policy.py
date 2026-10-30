"""Validate the staged guest floor. Does not install policy or prove isolation."""

import argparse
import json
import os
from pathlib import Path
import stat
import sys

TEMPLATE = Path(__file__).with_name("managed-settings.guest.json")


def validate(candidate):
    # Exact comparison deliberately rejects unreviewed additions as well as
    # missing keys. This is a release contract, not a complete vendor schema.
    expected = json.loads(TEMPLATE.read_text())
    if candidate != expected:
        raise ValueError("policy differs from reviewed guest floor")
    # Python equality considers 1 == True. JSON boolean types must be exact.
    if json.dumps(candidate, sort_keys=True) != json.dumps(expected, sort_keys=True):
        raise ValueError("policy types differ from reviewed guest floor")


def validate_install(path):
    path = Path(os.path.abspath(path))
    for part in (path, *path.parents):
        info = part.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("policy path contains symlink")
        if info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError("policy path must be root-owned and not writable")
    if not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("policy must be regular file")
    validate(json.loads(path.read_text()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path)
    parser.add_argument("--installed", action="store_true")
    args = parser.parse_args()
    try:
        if args.installed:
            validate_install(args.file)
        else:
            validate(json.loads(args.file.read_text()))
    except (ValueError, OSError):
        print("guest policy validation failed; do not launch", file=sys.stderr)
        return 1
    print("guest floor matches; runtime and host isolation remain unverified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
