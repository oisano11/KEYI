#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"

cd "$ROOT_DIR"
swift run HanYiCoreChecks
