# Inference Endpoints

`ASM.InferenceEndpoint` publishes CLI-backed ASM providers as
endpoint-shaped inference targets for northbound consumers such as
`jido_integration`.

## Stable API

The public northbound surface is intentionally small:

- `consumer_manifest/0`
- `ensure_endpoint/3`
- `release_endpoint/1`

`consumer_manifest/0` returns ASM's default completion-oriented consumer
contract for the published endpoint seam.

`ensure_endpoint/3` accepts:

- an inference-shaped request
- a consumer manifest
- execution context metadata

It returns:

- `%ASM.InferenceEndpoint.EndpointDescriptor{}`
- `%ASM.InferenceEndpoint.CompatibilityResult{}`

`release_endpoint/1` retires the lease-backed endpoint publication.

## Publication Rules

ASM publishes the built-in CLI providers:

- `:codex`
- `:claude`
- `:gemini`
- `:amp`

Capability publication is derived from the landed core provider profiles rather
than handwritten declarations.

Published metadata includes:

- `cli_completion_v1`
- `cli_streaming_v1`
- `cli_agent_v2`

That metadata is available on the compatibility result and backend manifest,
but the endpoint seam itself only exposes:

- completion requests
- streaming requests

It does not expose agent-loop semantics. Tool-bearing requests are rejected
both at compatibility time and on the HTTP route.

## Descriptor Contract

The published `%EndpointDescriptor{}` is OpenAI-compatible on purpose:

- `target_class: :cli_endpoint`
- `protocol: :openai_chat_completions`
- loopback `base_url`
- bearer auth header
- pinned `provider_identity`
- pinned `model_identity`
- `source_runtime: :agent_session_manager`

The returned `metadata` also carries:

- publication metadata
- backend manifest data

That lets northbound consumers keep the durable route record honest without
reconstructing provider claims themselves.

## Runtime Behavior

The endpoint server is lease-backed and loopback-only.

Under the published HTTP path:

- non-streaming requests execute through `ASM.query/3`
- streaming requests execute through `ASM.stream/3`
- the model is pinned to the published descriptor
- health is available on the lease health route

The northbound endpoint therefore reuses the same ASM event and result
projection path that ordinary session/query callers already consume.

## Provider Boundaries

Gemini and Amp remain common-surface-only providers.

They can publish:

- `cli_completion_v1`
- `cli_streaming_v1`
- `cli_agent_v2`

without gaining a separate ASM-native extension namespace. Claude and Codex
may still expose additional provider-native surfaces above this seam through
`ASM.Extensions.ProviderSDK`.

## Proof Surface

- `test/asm/inference_endpoint_test.exs`
- `examples/inference_endpoint_http.exs`
