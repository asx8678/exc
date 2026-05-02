#!/usr/bin/env python3
"""Fast smoke test for the code_puppy FastAPI app."""

import argparse
import sys
import time

from code_puppy.api.app import create_app
from fastapi.testclient import TestClient


class SmokeTestResult:
    def __init__(
        self,
        method: str,
        path: str,
        status_code: int,
        elapsed_ms: float,
        error: str | None = None,
    ):
        self.method, self.path = method, path
        self.status_code, self.elapsed_ms, self.error = status_code, elapsed_ms, error

    @property
    def success(self) -> bool:
        return self.error is None and self.status_code == 200


def run_test(client: TestClient, method: str, path: str) -> SmokeTestResult:
    start = time.perf_counter()
    try:
        response = client.request(method, path)
        elapsed_ms = (time.perf_counter() - start) * 1000
        return SmokeTestResult(method, path, response.status_code, elapsed_ms)
    except Exception as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        return SmokeTestResult(method, path, 0, elapsed_ms, error=str(e))


def format_result(result: SmokeTestResult) -> str:
    if result.success:
        return f"✅ {result.method} {result.path} → {result.status_code} ({result.elapsed_ms:.0f}ms)"
    if result.error:
        return f"❌ {result.method} {result.path} → ERROR: {result.error}"
    return f"❌ {result.method} {result.path} → {result.status_code} ({result.elapsed_ms:.0f}ms)"


def get_smoke_endpoints() -> list[tuple[str, str]]:
    """Return list of (method, path) tuples for smoke testing."""
    return [
        ("GET", "/health"),
        ("GET", "/api/agents/"),
        ("GET", "/api/commands/"),
        ("GET", "/api/config/"),
        ("GET", "/api/config/keys"),
    ]


def main(args: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="FastAPI smoke test")
    parser.add_argument(
        "--quiet", "-q", action="store_true", help="Only print failures"
    )
    parser.add_argument("--endpoint", "-e", help="Test single endpoint (e.g., /health)")
    parsed = parser.parse_args(args)

    app = create_app()
    client = TestClient(app)

    if parsed.endpoint:
        endpoints = [("GET", parsed.endpoint)]
    else:
        endpoints = get_smoke_endpoints()

    results: list[SmokeTestResult] = []
    failed: list[SmokeTestResult] = []

    for method, path in endpoints:
        result = run_test(client, method, path)
        results.append(result)
        if not result.success:
            failed.append(result)
        if not parsed.quiet:
            print(format_result(result))

    total = len(results)
    passed = total - len(failed)

    if not parsed.quiet or failed:
        print(f"\n{passed}/{total} endpoints passed")

    if failed:
        if parsed.quiet:
            for result in failed:
                print(format_result(result))
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
