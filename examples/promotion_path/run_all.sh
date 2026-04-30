#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT_DIR"

mix run --no-start examples/promotion_path/asm_core_lane.exs -- "$@"
mix run --no-start examples/promotion_path/asm_sdk_backed_lane.exs -- "$@"

if [[ " $* " == *" --provider gemini "* ]] || [[ " $* " == *" --provider=gemini "* ]]; then
  mix run --no-start examples/promotion_path/hybrid_asm_plus_gemini.exs -- "$@"
fi
