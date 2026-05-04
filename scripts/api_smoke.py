#!/usr/bin/env python3
"""Legacy entry point for the removed Python FastAPI smoke test.

The Python FastAPI control plane was retired in favor of the Elixir/Phoenix
control plane. Keeping this file as an explicit tombstone is safer than leaving
a broken import behind: direct users get a clear failure and release tooling can
point at the supported smoke commands.
"""

from __future__ import annotations

import argparse
import sys
from textwrap import dedent

LEGACY_MESSAGE = """
scripts/api_smoke.py is retired.

The Python FastAPI control plane was removed and replaced by the
Elixir/Phoenix control plane, so the old in-process FastAPI smoke test no
longer has a valid app to import.

Use the supported local smoke commands instead:

  cd elixir/code_puppy_control
  mix pup_ex.smoke
  ./scripts/smoke-packaged.sh

Or run the full local release gate from the repository root:

  ./scripts/release-gate.sh
""".strip()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Legacy notice for the retired Python FastAPI smoke test",
        epilog="This command exits non-zero unless --help is requested.",
    )
    parser.add_argument(
        "--quiet",
        "-q",
        action="store_true",
        help="Print a one-line legacy notice before exiting non-zero",
    )
    parser.add_argument(
        "--endpoint",
        "-e",
        metavar="PATH",
        help="Accepted for compatibility; ignored because the FastAPI app is gone",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    parsed = parser.parse_args(argv)

    if parsed.quiet:
        print(
            "scripts/api_smoke.py is retired; use mix pup_ex.smoke instead.",
            file=sys.stderr,
        )
    else:
        print(dedent(LEGACY_MESSAGE), file=sys.stderr)

    return 1


if __name__ == "__main__":
    sys.exit(main())
