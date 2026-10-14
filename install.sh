#!/usr/bin/env bash
# Foder — Official Installer
# Repository: https://github.com/frictionalmega/foder
#
# One-line install:
#   curl -fsSL https://foder.vercel.app/install.sh | bash
#
set -euo pipefail

FODER_REPO="https://github.com/frictionalmega/foder"
FODER_SITE="https://foder.vercel.app"
FODER_VERSION="0.1.0"

# ── Colors ─────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  GRN='\033[0;32m' YLW='\033[0;33m' RED='\033[0;31m'
  CYN='\033[0;36m' DIM='\033[2m'    BLD='\033[1m' RST='\033[0m'
else
  GRN='' YLW='' RED='' CYN='' DIM='' BLD='' RST=''
fi
ok()   { echo -e "  ${GRN}✓${RST}  $*"; }
warn() { echo -e "  ${YLW}!${RST}  $*"; }
err()  { echo -e "  ${RED}✗${RST}  $*"; exit 1; }
info() { echo -e "  ${DIM}→${RST}  ${DIM}$*${RST}"; }
sep()  { echo "  ─────────────────────────────────────────────────────────"; }

echo ""
echo -e "${CYN}${BLD}  ███████  ██████  ██████  ███████ ██████${RST}"
echo -e "${CYN}  ██      ██    ██ ██   ██ ██      ██   ██${RST}"
echo -e "${CYN}  █████   ██    ██ ██   ██ █████   ██████${RST}"
echo -e "${CYN}  ██      ██    ██ ██   ██ ██      ██   ██${RST}"
echo -e "${CYN}  ██       ██████  ██████  ███████ ██   ██${RST}"
echo ""
echo -e "${BLD}  Foder — Local AI Coding Agent  v${FODER_VERSION}${RST}"
echo -e "${DIM}  No cloud. No keys. Just code.${RST}"
echo -e "${DIM}  Source: ${FODER_SITE}${RST}"
echo ""
sep
echo ""

# ── Security: source verification ─────────────────────────────────────────────
# Foder source is fetched only from the official sources below:
#   install script: https://foder.vercel.app/install.sh
#   repository:     https://github.com/frictionalmega/foder
# No third-party mirrors are used.

# ── Prompt safely when run as `curl ... | bash` ───────────────────────────────
# When the script is piped on stdin, `read` would swallow the rest of the
# script instead of waiting for the user. Re-attach stdin to the terminal.
PROMPTS_OFF=0
if [ ! -t 0 ]; then
  # stdin is a pipe (curl | bash). Try to reattach to the terminal so
  # read-based prompts work. If /dev/tty is unavailable, disable prompts.
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    exec < /dev/tty 2>/dev/null || PROMPTS_OFF=1
  else
    PROMPTS_OFF=1
  fi
fi

ask_yn() {
  # ask_yn <prompt> <default: y|n>  →  returns 0 for yes, 1 for no.
  local prompt="$1" default="${2:-y}"
  if [ "$PROMPTS_OFF" = "1" ]; then
    echo ""
    echo "  (no terminal available — assuming '$default')"
    warn "Re-run interactively to confirm: $prompt"
    [ "$default" = "y" ] && return 0 || return 1
  fi
  local reply=""
  read -rp "$prompt" reply || reply="$default"
  reply="${reply:-$default}"
  reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"
  case "$reply" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

# ── Detect OS ──────────────────────────────────────────────────────────────────
OS="$(uname -s 2>/dev/null || echo unknown)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"
info "Platform: $OS ($ARCH)"

# ── Check Python 3.10+ ─────────────────────────────────────────────────────────
PYTHON=""
for cmd in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$cmd" &>/dev/null; then
    RAW_VER="$("$cmd" -c 'import sys;print(".".join(map(str,sys.version_info[:2])))'  2>/dev/null || echo "0.0")"
    MAJ="${RAW_VER%%.*}"; MIN="${RAW_VER#*.}"; MIN="${MIN%%.*}"
    if [ "$MAJ" -ge 3 ] 2>/dev/null && [ "$MIN" -ge 10 ] 2>/dev/null; then
      PYTHON="$cmd"; PY_VER="$RAW_VER"; break
    fi
  fi
done

if [ -z "$PYTHON" ]; then
  err "Python 3.10+ not found.

  Install it:
    Ubuntu/Debian:  sudo apt install python3.11
    Arch Linux:     sudo pacman -S python
    Fedora:         sudo dnf install python3
    macOS:          brew install python@3.11
    All platforms:  https://python.org/downloads/"
fi
ok "Python $PY_VER"

if ! "$PYTHON" -m pip --version &>/dev/null; then
  err "pip not found. Install python3-pip and retry."
fi
ok "pip available"

# ── Check Ollama ───────────────────────────────────────────────────────────────
if command -v ollama &>/dev/null; then
  OLLAMA_VER="$(ollama --version 2>/dev/null | head -1 || echo 'unknown')"
  ok "Ollama: $OLLAMA_VER"
else
  warn "Ollama not found."
  echo ""
  echo "  Foder requires Ollama to run local LLMs."
  echo -e "  Install: ${CYN}https://ollama.com${RST}"
  echo ""
  if ! ask_yn "  Continue without Ollama? [y/N] " "n"; then
    echo "  Install Ollama first, then re-run."
    exit 1
  fi
fi

# ── Get foder source ───────────────────────────────────────────────────────────
# Official sources:
#   installer: https://foder.vercel.app/install.sh
#   repository: https://github.com/frictionalmega/foder
INSTALL_DIR=""

if [ -f "pyproject.toml" ] && grep -q '"foder"' pyproject.toml 2>/dev/null; then
  # Already inside the repo (local dev / CI)
  INSTALL_DIR="$PWD"
  info "Using local repository: $INSTALL_DIR"
else
  INSTALL_DIR="$HOME/.foder_src"

  # Safety: never reuse/wipe a path outside the user's own home.
  case "$INSTALL_DIR" in
    "$HOME"/*) : ;;
    *) err "Refusing to use install path '$INSTALL_DIR' (outside \$HOME)." ;;
  esac

  if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing installation..."
    # Update in place — idempotent, no user data is stored in this directory.
    BRANCH="$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || BRANCH="main"
    git -C "$INSTALL_DIR" pull --rebase origin "$BRANCH" 2>/dev/null || \
    git -C "$INSTALL_DIR" pull origin "$BRANCH" 2>/dev/null || \
    warn "Could not update — continuing with the version already on disk"
  else
    # Only clear a leftover directory if it looks like foder's own source tree.
    if [ -e "$INSTALL_DIR" ] && [ ! -f "$INSTALL_DIR/pyproject.toml" ]; then
      warn "'$INSTALL_DIR' exists and is not a foder checkout — leaving it alone"
      INSTALL_DIR="$HOME/.foder_src"
    elif [ -d "$INSTALL_DIR" ]; then
      info "Refreshing incomplete checkout at $INSTALL_DIR"
      rm -rf "$INSTALL_DIR"
    fi

    info "Fetching foder from $FODER_REPO..."
    if command -v git &>/dev/null && git clone --depth=1 "$FODER_REPO" "$INSTALL_DIR"; then
      ok "Cloned $FODER_REPO"
    else
      # Fallback: source tarball from GitHub codeload (needs no git binary).
      warn "git clone unavailable — falling back to the GitHub source archive"
      TARBALL_URL="$FODER_REPO/archive/refs/heads/main.tar.gz"
      TARBALL_TMP="$(mktemp -d)"
      if command -v curl &>/dev/null; then
        curl -fsSL "$TARBALL_URL" -o "$TARBALL_TMP/foder.tar.gz"
      elif command -v wget &>/dev/null; then
        wget -q "$TARBALL_URL" -O "$TARBALL_TMP/foder.tar.gz"
      else
        rm -rf "$TARBALL_TMP"
        err "Neither git, curl nor wget is available. Install one of them and retry:
  Ubuntu/Debian:  sudo apt install git curl
  macOS:          brew install git
  All platforms:  see $FODER_REPO"
      fi
      tar -xzf "$TARBALL_TMP/foder.tar.gz" -C "$TARBALL_TMP"
      rm -f "$TARBALL_TMP/foder.tar.gz"
      # The archive extracts to foder-main/ — normalise the layout to $INSTALL_DIR
      SRC_DIR="$(find "$TARBALL_TMP" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
      if [ -z "$SRC_DIR" ] || [ ! -f "$SRC_DIR/pyproject.toml" ]; then
        rm -rf "$TARBALL_TMP"
        err "Downloaded archive from $TARBALL_URL does not contain a foder source tree."
      fi
      rm -rf "$INSTALL_DIR"
      mkdir -p "$INSTALL_DIR"
      cp -R "$SRC_DIR/." "$INSTALL_DIR/"
      rm -rf "$TARBALL_TMP"
      ok "Source archive downloaded and unpacked"
      warn "Installed from a snapshot — run 'foder --update' after git is available"
    fi
  fi
fi

[ -n "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/pyproject.toml" ] || err "Could not obtain foder source."

# ── Install foder ──────────────────────────────────────────────────────────────
echo ""
info "Installing foder..."

cd "$INSTALL_DIR"

INSTALL_OK=false
PIP_ERR_LOG="$(mktemp)"
: > "$PIP_ERR_LOG"
for flags in "-q" "--user -q" "--user" "--break-system-packages -q"; do
  # shellcheck disable=SC2086
  if "$PYTHON" -m pip install -e . $flags 2>>"$PIP_ERR_LOG"; then
    INSTALL_OK=true; break
  fi
  echo "" >> "$PIP_ERR_LOG"
done

if [ "$INSTALL_OK" != "true" ]; then
  warn "pip reported:"
  sed -n '1,15p' "$PIP_ERR_LOG" | sed 's/^/      /'
  rm -f "$PIP_ERR_LOG"
  err "pip install failed. Try manually:
  cd $INSTALL_DIR && pip install -e .
Or, on Debian/Ubuntu with PEP 668:  pip install --user -e ."
fi
rm -f "$PIP_ERR_LOG"

# ── Create ~/.foder directory structure ────────────────────────────────────────
# Only creates missing directories — an existing ~/.foder/ is never touched,
# so memories, preferences, sessions and history survive reinstalls/upgrades.
FODER_DIR="$HOME/.foder"
if [ -e "$FODER_DIR" ] && [ ! -d "$FODER_DIR" ]; then
  err "'$FODER_DIR' exists but is not a directory. Move or remove it and retry."
fi
mkdir -p \
  "$FODER_DIR/skills" \
  "$FODER_DIR/sessions"
ok "$HOME/.foder/ directory ready"

# ── Verify installation ─────────────────────────────────────────────────────────
echo ""
if command -v foder &>/dev/null; then
  FODER_PATH="$(command -v foder)"
  ok "foder installed: $FODER_PATH"
else
  LOCAL_BIN="$HOME/.local/bin"
  if [ -f "$LOCAL_BIN/foder" ]; then
    ok "foder installed to $LOCAL_BIN"
    warn "Add to PATH — run this and restart your terminal:"
    echo ""
    echo -e "    ${CYN}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc${RST}"
    echo -e "    ${CYN}source ~/.bashrc${RST}"
    echo ""
  else
    warn "foder installed. Restart your terminal and run 'foder'."
    warn "If it doesn't work: pip install -e $INSTALL_DIR"
  fi
fi

# ── Optional: pull starter model ──────────────────────────────────────────────
if command -v ollama &>/dev/null; then
  if ! ollama list 2>/dev/null | grep -q "qwen2.5-coder"; then
    echo ""
    echo -e "  ${DIM}Recommended starter model: qwen2.5-coder:3b (~2GB)${RST}"
    if ask_yn "  Pull it now? [Y/n] " "y"; then
      info "Pulling qwen2.5-coder:3b..."
      ollama pull qwen2.5-coder:3b && ok "Model ready — this is your default coding model"
    else
      info "Skipped. Pull one later with:  ollama pull qwen2.5-coder:3b"
    fi
  else
    ok "qwen2.5-coder already available"
  fi
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
sep
echo ""
echo -e "  ${GRN}${BLD}Installation complete!${RST}"
echo ""
echo -e "  ${BLD}Start:${RST}    ${CYN}foder${RST}"
echo -e "  ${BLD}Help:${RST}     ${CYN}foder --help${RST}"
echo -e "  ${BLD}Update:${RST}   ${CYN}foder --update${RST}"
echo -e "  ${BLD}Uninstall:${RST} ${CYN}foder --uninstall${RST}"
echo ""
echo -e "  ${DIM}Before starting, make sure Ollama is running:  ollama serve${RST}"
echo -e "  ${DIM}Website:  $FODER_SITE${RST}"
echo -e "  ${DIM}GitHub:   $FODER_REPO${RST}"
echo ""
