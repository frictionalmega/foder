"""
Release-readiness tests for Foder v0.1.0.

These guard the things a release engineer checks by hand and that silently rot:
version metadata drift, the canonical repository URL, installer/update
consistency, and the user-data safety of `foder --update`.

All of them are pure unit tests — no Ollama and no network required.
"""

import re
import subprocess
import sys
from pathlib import Path

import httpx
import pytest

import foder
import foder.config as config
from foder import cli
from foder.llm import _http_error_message, _model_missing_message

REPO_ROOT = Path(__file__).resolve().parent.parent
CANONICAL = "https://github.com/frictionalmega/foder"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _pyproject_version() -> str:
    """Version from pyproject.toml, parsed without a hard tomllib dependency."""
    text = _read(REPO_ROOT / "pyproject.toml")
    try:
        import tomllib  # Python 3.11+
        return tomllib.loads(text)["project"]["version"]
    except ModuleNotFoundError:  # Python 3.10
        m = re.search(r'^version\s*=\s*"([^"]+)"', text, re.MULTILINE)
        assert m, "no version found in pyproject.toml"
        return m.group(1)


# ── Version metadata ──────────────────────────────────────────────────────────

def test_package_version_matches_pyproject() -> None:
    assert foder.__version__ == _pyproject_version()


def test_installers_declare_the_package_version() -> None:
    for name in ("install.sh", "install.ps1"):
        text = _read(REPO_ROOT / name)
        m = re.search(r'FODER_VERSION\s*=\s*"([^"]+)"', text)
        assert m, f"{name} does not declare FODER_VERSION"
        assert m.group(1) == foder.__version__, \
            f"{name} ships FODER_VERSION {m.group(1)}, package is {foder.__version__}"


def test_no_stale_version_string_in_package_source() -> None:
    """Shipped package source must not advertise an older version than it is."""
    for py in sorted(REPO_ROOT.glob("foder/**/*.py")):
        if py.name == "__init__.py":
            continue  # this file is the source of truth
        text = _read(py)
        for stale in ("v0.0.", "v0.2.0", "v0.3.0"):
            assert stale not in text, f"{py.name} still contains '{stale}'"


# ── Canonical repository ──────────────────────────────────────────────────────

def test_cli_points_at_the_canonical_repository() -> None:
    assert cli.GITHUB_REPO == CANONICAL


def test_no_old_repository_references_in_tracked_files() -> None:
    """Nothing that ships may still point at the previous GitHub username."""
    old_user   = "Frictional" + "for"          # assembled so this test can't flag itself
    stale_urls = (f"{old_user}/foder", f"github.com/{old_user}")
    bad: list[str] = []
    for path in sorted(REPO_ROOT.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(REPO_ROOT)
        if any(part == ".git" for part in rel.parts):
            continue
        if path.suffix not in {".py", ".md", ".sh", ".ps1", ".toml", ".json", ".yml", ".txt"}:
            continue
        try:
            text = _read(path)
        except (UnicodeDecodeError, OSError):
            continue
        if any(s in text for s in stale_urls):
            bad.append(str(rel))
    assert bad == [], f"references to the old repository remain: {bad}"


def test_installers_fetch_from_the_canonical_repository() -> None:
    assert 'FODER_REPO="%s"' % CANONICAL in _read(REPO_ROOT / "install.sh")
    assert '$FODER_REPO    = "%s"' % CANONICAL in _read(REPO_ROOT / "install.ps1")


def test_update_uses_the_canonical_repository() -> None:
    """`foder --update` must pull from the same repo the installer cloned."""
    text = _read(REPO_ROOT / "foder" / "cli.py")
    assert "git+{GITHUB_REPO}.git" in text
    assert "Frictionalfor" not in text


# ── Update: user data safety ──────────────────────────────────────────────────

def _git(args: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.com"] + args,
        cwd=str(cwd), capture_output=True, text=True, timeout=60,
    )


@pytest.fixture()
def scratch_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "src"
    repo.mkdir()
    _git(["init", "-q", "--initial-branch=main"], repo)
    (repo / "pyproject.toml").write_text('[project]\nname = "foder"\n', encoding="utf-8")
    _git(["add", "-A"], repo)
    _git(["commit", "-q", "-m", "init"], repo)
    return repo


def test_backup_and_restore_user_data_roundtrip(tmp_path: Path) -> None:
    user_dir = tmp_path / "foder-home"
    (user_dir / "sessions").mkdir(parents=True)
    (user_dir / "preferences.json").write_text('{"theme": "teal"}', encoding="utf-8")
    (user_dir / "audit.log").write_text("line\n", encoding="utf-8")

    backup = tmp_path / "backup"
    cli._backup_user_data(user_dir, backup)
    assert (backup / "preferences.json").read_text(encoding="utf-8") == '{"theme": "teal"}'

    (user_dir / "preferences.json").write_text("{}", encoding="utf-8")
    cli._restore_user_data(backup, user_dir)
    assert (user_dir / "preferences.json").read_text(encoding="utf-8") == '{"theme": "teal"}'

    cli._cleanup_backup(backup)
    assert not backup.exists()


def test_restore_user_data_never_deletes_newer_files(tmp_path: Path) -> None:
    user_dir = tmp_path / "home"
    user_dir.mkdir()
    backup = tmp_path / "backup"
    backup.mkdir()
    (backup / "preferences.json").write_text('{"a": 1}', encoding="utf-8")
    (user_dir / "preferences.json").write_text('{"a": 2}', encoding="utf-8")
    (user_dir / "written-after-backup.json").write_text("{}", encoding="utf-8")

    cli._restore_user_data(backup, user_dir)
    # additive merge: files that only exist post-backup are never deleted,
    # and files the backup knows about are brought back to that state.
    assert (user_dir / "written-after-backup.json").exists()
    assert (user_dir / "preferences.json").read_text(encoding="utf-8") == '{"a": 1}'


def test_update_stash_roundtrip_preserves_uncommitted_work(scratch_repo: Path) -> None:
    (scratch_repo / "pyproject.toml").write_text("[project]\n# local edit\n", encoding="utf-8")
    assert cli._stash_local_changes(scratch_repo) is True

    # simulate the pull landing upstream work, then pop the stash back
    (scratch_repo / "pyproject.toml").write_text("[project]\n# upstream change\n", encoding="utf-8")
    _git(["add", "-A"], scratch_repo)
    _git(["commit", "-q", "-m", "upstream"], scratch_repo)

    cli._restore_stash(scratch_repo)
    text = (scratch_repo / "pyproject.toml").read_text(encoding="utf-8")
    assert "local edit" in text, "stashed local work was not restored"


def test_stash_not_created_when_tree_is_clean(scratch_repo: Path) -> None:
    assert cli._stash_local_changes(scratch_repo) is False


def test_current_branch_is_detected(scratch_repo: Path, tmp_path: Path) -> None:
    assert cli._current_branch(scratch_repo) == "main"
    assert cli._current_branch(tmp_path / "does-not-exist") == ""


# ── Ollama error handling ─────────────────────────────────────────────────────

def _status_error(status_code: int, body: str) -> httpx.HTTPStatusError:
    response = httpx.Response(status_code, text=body,
                              request=httpx.Request("POST", "http://localhost:11434/api/chat"))
    return httpx.HTTPStatusError("boom", request=response.request, response=response)


def test_model_not_found_is_actionable() -> None:
    msg = _http_error_message(_status_error(404, "model 'foo:1b' not found"), "foo:1b")
    assert "ollama pull foo:1b" in msg
    assert "not installed" in msg


def test_model_missing_message_mentions_pull_and_switch() -> None:
    msg = _model_missing_message("qwen2.5-coder:3b")
    assert "ollama pull qwen2.5-coder:3b" in msg
    assert "/switch" in msg


def test_other_http_errors_are_reported_verbatim() -> None:
    msg = _http_error_message(_status_error(500, "internal error"), "qwen2.5-coder:3b")
    assert "HTTP 500" in msg
    assert "internal error" in msg


def test_connection_error_and_missing_model_stay_distinct() -> None:
    assert "ollama pull" not in _http_error_message(_status_error(503, "upstream down"), "m")


# ── Config ────────────────────────────────────────────────────────────────────

def test_foder_json_can_set_temperature(monkeypatch, tmp_path) -> None:
    monkeypatch.delenv("FODER_LLM_TEMPERATURE", raising=False)
    monkeypatch.setenv("OLLAMA_MODEL", "dummy-model")  # no model auto-detection / network
    ws = tmp_path / "ws"
    ws.mkdir()
    (ws / "foder.json").write_text('{"llm_temperature": 0.7}', encoding="utf-8")

    monkeypatch.setattr(config, "WORKSPACE", ws)
    config.load_project_config()
    try:
        assert config.LLM_TEMPERATURE == 0.7
    finally:
        config.LLM_TEMPERATURE = 0.1


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
