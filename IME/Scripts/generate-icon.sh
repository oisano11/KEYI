#!/usr/bin/env bash
# Writes the input mode icon into a bundle Resources directory.
#
# Usage: Scripts/generate-icon.sh /path/to/Contents/Resources
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="${1:?usage: Scripts/generate-icon.sh RESOURCES_DIR}"
mkdir -p "$RESOURCES_DIR"

swift "$PROJECT_ROOT/Scripts/generate-icon.swift" "$RESOURCES_DIR"
