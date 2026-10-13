#!/bin/bash
# Foder Installer for Linux/macOS
set -e
echo 'Foder - Local AI Coding Agent Installer'
mkdir -p /usr/local/bin
echo 'Copying binary...'
cp foder /usr/local/bin/ 2>/dev/null || true
echo 'Installation complete.'
chmod +x /usr/local/bin/foder
