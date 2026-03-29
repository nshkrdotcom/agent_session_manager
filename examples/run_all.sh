#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLES=(
  "live_query.exs"
  "live_stream.exs"
  "live_session_lifecycle.exs"
)

declare -A PROVIDER_SPECIFIC_EXAMPLE=(
  [amp]="provider_amp_sdk_stream.exs"
  [claude]="provider_claude_control_client.exs"
  [codex]="provider_codex_app_server.exs"
  [gemini]="provider_gemini_session_resume.exs"
)

usage() {
  cat <<'EOF'
run_all.sh only runs when you explicitly choose one or more providers.

Usage:
  ./examples/run_all.sh --provider claude
  ./examples/run_all.sh --provider codex --model gpt-5.4
  ./examples/run_all.sh --provider claude --ollama --model haiku --ollama-model llama3.2
  ./examples/run_all.sh --provider codex --ollama --ollama-model gpt-oss:20b
  ./examples/run_all.sh --provider claude --provider codex --ollama --ollama-model llama3.2
  ./examples/run_all.sh --provider claude --provider gemini
  ./examples/run_all.sh --provider amp --lane sdk --sdk-root ../amp_sdk
  ./examples/run_all.sh --provider codex --ssh-host example.internal
  ./examples/run_all.sh --provider claude --ssh-host builder@example.internal --ssh-port 2222

Notes:
  - Repeat --provider or pass a comma-separated list.
  - Any other flags are forwarded to each example.
  - Each example also requires --provider when run directly.
  - Common and provider-native examples default to ASM permission_mode=:bypass.
  - The examples print the provider-native permission term at startup.
  - --ollama and the related --ollama-* flags are only valid for claude and codex.
  - Provider-specific examples may require the matching SDK checkout on the code path or via --sdk-root.
EOF
}

providers=()
forward_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      if [[ $# -lt 2 ]]; then
        echo "--provider requires a value" >&2
        exit 1
      fi

      providers+=("$2")
      shift 2
      ;;
    --provider=*)
      providers+=("${1#*=}")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      forward_args+=("$1")
      shift
      ;;
  esac
done

if [[ ${#providers[@]} -eq 0 ]]; then
  usage
  exit 0
fi

ollama_requested=0

for arg in "${forward_args[@]}"; do
  case "$arg" in
    --ollama|--ollama=*|--ollama-model|--ollama-model=*|--ollama-base-url|--ollama-base-url=*|--ollama-http|--ollama-timeout-ms|--ollama-timeout-ms=*)
      ollama_requested=1
      ;;
  esac
done

declare -A seen=()
selected_providers=()

for raw in "${providers[@]}"; do
  IFS=',' read -r -a split_values <<<"$raw"

  for value in "${split_values[@]}"; do
    provider="${value,,}"
    provider="${provider// /}"

    case "$provider" in
      claude|gemini|codex|amp)
        if [[ -z "${seen[$provider]:-}" ]]; then
          seen["$provider"]=1
          selected_providers+=("$provider")
        fi
        ;;
      "")
        ;;
      *)
        echo "unsupported provider: $value" >&2
        exit 1
        ;;
    esac
  done
done

cd "$ROOT_DIR"

for provider in "${selected_providers[@]}"; do
  if [[ $ollama_requested -eq 1 ]]; then
    case "$provider" in
      claude|codex)
        ;;
      *)
        echo "provider $provider does not support the ASM common Ollama surface; --ollama* flags are only valid for claude and codex" >&2
        exit 1
        ;;
    esac
  fi

  for example in "${EXAMPLES[@]}"; do
    echo
    echo "== ${example} provider=${provider} =="
    mix run --no-start "examples/${example}" -- --provider "$provider" "${forward_args[@]}"
  done

  specific_example="${PROVIDER_SPECIFIC_EXAMPLE[$provider]}"

  if [[ -n "${specific_example:-}" ]]; then
    echo
    echo "== ${specific_example} provider=${provider} =="
    mix run --no-start "examples/${specific_example}" -- --provider "$provider" "${forward_args[@]}"
  fi
done
