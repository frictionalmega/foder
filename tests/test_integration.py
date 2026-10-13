"""
Foder on-site test runner.
Tests real agent tasks against Ollama.
Workspace: /tmp/foder_integration_test (created automatically if missing)

Run with:
    python3 tests/test_integration.py
Requires:
    ollama running with at least one model pulled.

NOTE: nothing in this module runs at import time. Importing it under pytest
must not create directories, rewrite foder.config.WORKSPACE, or touch the
network — all of that happens inside main() when the file is run directly.
"""
import os
import sys
import time
import shutil
import tempfile
from pathlib import Path

import foder.config as config

from foder.agent import run  # noqa: E402

PASS  = "\033[92mPASS\033[0m"
FAIL  = "\033[91mFAIL\033[0m"
INFO  = "\033[94mINFO\033[0m"

results: list[tuple[str, bool, str]] = []

# Set by main() when this file is run directly — never at import time.
WORKSPACE: Path | None = None


def _setup_workspace() -> Path:
    """Create the scratch workspace and point foder at it."""
    global WORKSPACE
    ws = Path(os.environ.get(
        "FODER_TEST_WORKSPACE", tempfile.gettempdir() + "/foder_integration_test"
    ))
    ws.mkdir(parents=True, exist_ok=True)
    config.WORKSPACE = ws
    config.load_project_config()
    WORKSPACE = ws
    return ws


def ollama_available() -> bool:
    """True when the local Ollama API answers. No exceptions leak out."""
    try:
        import httpx
        httpx.get(f"{config.OLLAMA_BASE_URL}/api/tags", timeout=2.0)
        return True
    except Exception:
        return False


def test_ollama_api_is_reachable() -> None:
    """
    Sanity check for the local LLM the agent depends on.

    Skipped — not failed — when Ollama is not running, so `pytest tests/`
    stays green on machines (and CI runners) without a local model.
    """
    if not ollama_available():
        import pytest
        pytest.skip(
            f"Ollama is not reachable at {config.OLLAMA_BASE_URL} — "
            "run `ollama serve` to execute the live integration suite."
        )
    assert ollama_available()


def clean_workspace() -> None:
    """Remove all files from the test workspace between suites."""
    assert WORKSPACE is not None, "clean_workspace() called before main()"
    for p in WORKSPACE.iterdir():
        try:
            if p.is_dir():
                shutil.rmtree(p)
            else:
                p.unlink()
        except Exception:
            pass


def task(
    name: str,
    prompt: str,
    expect_files: list[str] | None = None,
    expect_text:  list[str] | None = None,
    timeout: int = 120,
) -> None:
    """Run a single agent task and verify the results."""
    print(f"\n{'─' * 60}")
    print(f"  {INFO}  {name}")
    print(f"  prompt: {prompt[:80]}{'...' if len(prompt) > 80 else ''}")
    print(f"{'─' * 60}")

    history: list[dict] = []
    start = time.monotonic()

    try:
        token_gen, history = run(prompt, history)
        response = "".join(token_gen)   # fully consume — safe, token_gen is a list generator
        elapsed  = time.monotonic() - start
    except Exception as e:
        print(f"  {FAIL}  Exception: {e}")
        results.append((name, False, str(e)))
        return

    # Show a preview of the response (stripped of any JSON that might have leaked)
    preview = response[:200].replace("\n", " ")
    print(f"  response: {preview}")
    print(f"  time: {elapsed:.1f}s")

    tool_calls = sum(
        1 for m in history
        if m["role"] == "user" and m["content"].startswith("[tool:")
    )
    print(f"  tool calls: {tool_calls}")

    passed = True
    errors: list[str] = []

    # Check for JSON leaking into response (bug 1)
    if '"tool"' in response and '"parameters"' in response:
        print(f"  {FAIL}  JSON leaked into response!")
        passed = False
        errors.append("raw JSON in response")

    # Check expected files exist
    if expect_files:
        for f in expect_files:
            p = WORKSPACE / f
            exists = p.exists()
            icon   = PASS if exists else FAIL
            print(f"  {icon}  file: {f}")
            if not exists:
                passed = False
                errors.append(f"missing: {f}")

    # Check expected text in response
    if expect_text:
        for t in expect_text:
            found = t.lower() in response.lower()
            icon  = PASS if found else FAIL
            print(f"  {icon}  response contains: '{t}'")
            if not found:
                passed = False
                errors.append(f"response missing: '{t}'")

    results.append((name, passed, ", ".join(errors) if errors else "ok"))
    status = PASS if passed else FAIL
    print(f"\n  {status}  {name}")


def main() -> None:
    _setup_workspace()

    print("\n" + "=" * 60)
    print("  FODER AGENT TEST SUITE")
    print(f"  workspace: {WORKSPACE}")
    print("=" * 60)

    clean_workspace()

    # T1 — Single file creation
    task(
        name="Create Python file",
        prompt='create a python file called greet.py that prints "Hello from Foder"',
        expect_files=["greet.py"],
    )

    # T2 — File with logic
    task(
        name="Create calculator",
        prompt="create a python file called calc.py that defines add(a,b) and prints add(3,4)",
        expect_files=["calc.py"],
    )

    # T3 — Directory creation
    task(
        name="Create directory",
        prompt="create a directory called test-output",
        expect_files=["test-output"],
    )

    # T4 — List files (multi-step: list after previous creates)
    task(
        name="List workspace files",
        prompt="list all files in the current directory",
        expect_text=["greet", "calc"],
    )

    # T5 — Read + edit existing file
    task(
        name="Edit existing file",
        prompt='read greet.py and add a second print statement that says "Version 1.0"',
        expect_files=["greet.py"],
    )

    # T6 — C file
    task(
        name="Create C file",
        prompt='create a C file called hello.c that prints "Hello from C"',
        expect_files=["hello.c"],
    )

    # T7 — Run a Python file
    task(
        name="Run Python file",
        prompt="run greet.py using python3",
        expect_text=["Hello"],
    )

    # T8 — MULTI-FILE: Python package with 2 files (bug 2 regression test)
    task(
        name="Multi-file: Python package",
        prompt=(
            "create two python files: "
            "utils.py that defines a function greet(name) returning 'Hello ' + name, "
            "and main.py that imports greet from utils and prints greet('Foder')"
        ),
        expect_files=["utils.py", "main.py"],
    )

    # T9 — MULTI-FILE: HTML + CSS
    task(
        name="Multi-file: HTML + CSS",
        prompt=(
            "create a simple webpage: index.html with a heading 'Hello Foder' "
            "and style.css that makes the heading green"
        ),
        expect_files=["index.html", "style.css"],
    )

    # T10 — Shell command
    task(
        name="Shell: echo command",
        prompt="run the shell command: echo 'foder_test_ok'",
        expect_text=["foder_test_ok"],
    )

    # ── Summary ────────────────────────────────────────────────────────────────────

    print("\n" + "=" * 60)
    print("  RESULTS")
    print("=" * 60)

    passed_count = sum(1 for _, p, _ in results if p)
    failed_count = sum(1 for _, p, _ in results if not p)

    for name, p, msg in results:
        icon = PASS if p else FAIL
        print(f"  {icon}  {name:<36}  {msg}")

    print(f"\n  {passed_count} passed  {failed_count} failed  ({len(results)} total)")
    print("=" * 60 + "\n")

    sys.exit(0 if failed_count == 0 else 1)


if __name__ == "__main__":
    main()
