#!/usr/bin/env bash
# Run AgentSessionManager examples.
#
# Usage:
#   ./examples/run_all.sh                  # Run all providers (claude, codex, amp)
#   ./examples/run_all.sh --provider amp   # Run only amp examples
#   ./examples/run_all.sh -p claude        # Run only claude examples
#
# Requires SDK authentication (e.g. `claude login` / `codex login` / `amp login`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

# ============================================================================
# Argument parsing
# ============================================================================

PROVIDER=""

print_usage() {
  cat <<EOF

Usage: ./examples/run_all.sh [options]

Options:
  --provider, -p <name>  Run examples for a single provider (claude, codex, or amp).
                         Default: run all providers.
  --help, -h             Show this help message.

Examples:
  ./examples/run_all.sh                  Run all providers
  ./examples/run_all.sh --provider amp   Run only Amp examples
  ./examples/run_all.sh -p claude        Run only Claude examples

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider|-p)
      PROVIDER="$2"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
done

if [[ -n "$PROVIDER" ]] && [[ "$PROVIDER" != "claude" && "$PROVIDER" != "codex" && "$PROVIDER" != "amp" ]]; then
  echo "Unknown provider: $PROVIDER"
  echo "Valid providers: claude, codex, amp"
  exit 1
fi

# ============================================================================
# Build the run plan
# ============================================================================

# Determine which providers to run
if [[ -n "$PROVIDER" ]]; then
  PROVIDERS=("$PROVIDER")
  MODE="single provider: $PROVIDER"
else
  PROVIDERS=("claude" "codex" "amp")
  MODE="all providers"
fi

# Collect planned examples into arrays
PLAN_NAMES=()
PLAN_FILES=()
PLAN_ARGS=()

for p in "${PROVIDERS[@]}"; do
  label="$(echo "${p:0:1}" | tr '[:lower:]' '[:upper:]')${p:1}"

  PLAN_NAMES+=("Cursor Pagination ($label)")
  PLAN_FILES+=("examples/cursor_pagination.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Cursor Follow Stream ($label)")
  PLAN_FILES+=("examples/cursor_follow_stream.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Cursor Wait Follow ($label)")
  PLAN_FILES+=("examples/cursor_wait_follow.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Session Continuity ($label)")
  PLAN_FILES+=("examples/session_continuity.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Workspace Snapshot ($label)")
  PLAN_FILES+=("examples/workspace_snapshot.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Provider Routing ($label)")
  PLAN_FILES+=("examples/provider_routing.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Policy Enforcement ($label)")
  PLAN_FILES+=("examples/policy_enforcement.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Session Runtime ($label)")
  PLAN_FILES+=("examples/session_runtime.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Interactive Interrupt ($label)")
  PLAN_FILES+=("examples/interactive_interrupt.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Session Subscriptions ($label)")
  PLAN_FILES+=("examples/session_subscription.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Session Limiter ($label)")
  PLAN_FILES+=("examples/session_limiter.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Session Concurrency ($label)")
  PLAN_FILES+=("examples/session_concurrency.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("One-Shot ($label)")
  PLAN_FILES+=("examples/oneshot.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Live Session ($label)")
  PLAN_FILES+=("examples/live_session.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Common Surface ($label)")
  PLAN_FILES+=("examples/common_surface.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Contract Surface ($label)")
  PLAN_FILES+=("examples/contract_surface_live.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Routing v2 ($label)")
  PLAN_FILES+=("examples/routing_v2.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Policy v2 ($label)")
  PLAN_FILES+=("examples/policy_v2.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Approval Gates ($label)")
  PLAN_FILES+=("examples/approval_gates.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Permission Mode ($label)")
  PLAN_FILES+=("examples/permission_mode.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Stream Session ($label)")
  PLAN_FILES+=("examples/stream_session.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Stream Session Raw ($label)")
  PLAN_FILES+=("examples/stream_session.exs")
  PLAN_ARGS+=("--provider $p --mode raw")

  PLAN_NAMES+=("Rendering Compact ($label)")
  PLAN_FILES+=("examples/rendering_compact.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Rendering Verbose ($label)")
  PLAN_FILES+=("examples/rendering_verbose.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Rendering Multi-Sink ($label)")
  PLAN_FILES+=("examples/rendering_multi_sink.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("Rendering Callback ($label)")
  PLAN_FILES+=("examples/rendering_callback.exs")
  PLAN_ARGS+=("--provider $p")

  PLAN_NAMES+=("$label Direct Features")
  PLAN_FILES+=("examples/${p}_direct.exs")
  PLAN_ARGS+=("")
done

# Persistence examples (no provider needed)
PLAN_NAMES+=("SQLite via Ecto SessionStore")
PLAN_FILES+=("examples/sqlite_session_store_live.exs")
PLAN_ARGS+=("")

PLAN_NAMES+=("Ecto SessionStore")
PLAN_FILES+=("examples/ecto_session_store_live.exs")
PLAN_ARGS+=("")

PLAN_NAMES+=("S3 ArtifactStore")
PLAN_FILES+=("examples/s3_artifact_store_live.exs")
PLAN_ARGS+=("")

PLAN_NAMES+=("Composite Store")
PLAN_FILES+=("examples/composite_store_live.exs")
PLAN_ARGS+=("")

# Persistence query, maintenance, and multi-run examples (no provider needed)
PLAN_NAMES+=("Persistence Query API")
PLAN_FILES+=("examples/persistence_query.exs")
PLAN_ARGS+=("")

PLAN_NAMES+=("Persistence Maintenance")
PLAN_FILES+=("examples/persistence_maintenance.exs")
PLAN_ARGS+=("")

PLAN_NAMES+=("Persistence Multi-Run")
PLAN_FILES+=("examples/persistence_multi_run.exs")
PLAN_ARGS+=("")

# Persistence live example (requires provider SDK)
for p in "${PROVIDERS[@]}"; do
  label="$(echo "${p:0:1}" | tr '[:lower:]' '[:upper:]')${p:1}"

  PLAN_NAMES+=("Persistence Live ($label)")
  PLAN_FILES+=("examples/persistence_live.exs")
  PLAN_ARGS+=("--provider $p")
done

# Note: persistence_s3_minio.exs requires Docker/MinIO and is not included in the default run.
# Run manually: MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin mix run examples/persistence_s3_minio.exs

TOTAL=${#PLAN_NAMES[@]}

# ============================================================================
# Print run header
# ============================================================================

echo ""
echo "========================================"
echo " AgentSessionManager Examples"
echo "========================================"
echo ""
echo "  Mode:      $MODE"
echo "  Providers: ${PROVIDERS[*]}"
echo "  Examples:  $TOTAL"
echo ""
echo "  Tip: Use --provider <name> to run a single provider."
echo "        e.g. ./examples/run_all.sh --provider amp"
echo ""
echo "  Plan:"
for (( i=0; i<TOTAL; i++ )); do
  printf "    %2d. %s\n" $((i + 1)) "${PLAN_NAMES[$i]}"
done
echo ""
echo "========================================"
echo ""

# ============================================================================
# Execute
# ============================================================================

PASS=0
FAIL=0

run_example() {
  local name="$1"
  local file="$2"
  shift 2

  echo "--- $name ---"
  if mix run "$file" "$@"; then
    echo ""
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo ""
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

for (( i=0; i<TOTAL; i++ )); do
  # shellcheck disable=SC2086
  run_example "${PLAN_NAMES[$i]}" "${PLAN_FILES[$i]}" ${PLAN_ARGS[$i]}
done

# ============================================================================
# Summary
# ============================================================================

echo "========================================"
echo " Results: $PASS passed, $FAIL failed (of $TOTAL)"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
