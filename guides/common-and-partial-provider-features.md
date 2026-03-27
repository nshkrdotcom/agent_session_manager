# Common And Partial Provider Features

ASM exposes a single common session API across four providers, but not every
provider supports every feature.

`ASM.ProviderFeatures` is the public discovery surface for that reality.

It answers two questions:

- what provider-native term does ASM map a normalized permission mode onto?
- which ASM common features are available for this provider?

## Discover Provider Features

```elixir
iex> ASM.ProviderFeatures.manifest!(:codex)
%{
  provider: :codex,
  permission_modes: %{...},
  common_features: %{ollama: %{supported?: true, ...}}
}
```

For one feature:

```elixir
iex> ASM.ProviderFeatures.common_feature!(:claude, :ollama)
%{
  supported?: true,
  common_surface: true,
  common_opts: [:ollama, :ollama_model, :ollama_base_url, :ollama_http, :ollama_timeout_ms],
  activation: %{provider_backend: :ollama},
  model_strategy: :canonical_or_direct_external,
  notes: [...]
}
```

## Common Permission Mode

ASM keeps the public knob normalized as `:permission_mode`, then maps it to the
provider-native form during validation.

Examples:

- Claude `:bypass` -> `:bypass_permissions`
- Gemini `:bypass` -> `:yolo`
- Codex `:bypass` -> `:yolo`
- Amp `:bypass` -> `:dangerously_allow_all`

If you need to present the native term:

```elixir
iex> ASM.ProviderFeatures.permission_mode!(:amp, :dangerously_allow_all)
%{
  native_mode: :dangerously_allow_all,
  cli_args: ["--dangerously-allow-all"],
  cli_excerpt: "--dangerously-allow-all",
  label: "dangerously_allow_all"
}
```

## Common Ollama Surface

ASM now exposes a common Ollama surface:

- `:ollama`
- `:ollama_model`
- `:ollama_base_url`
- `:ollama_http`
- `:ollama_timeout_ms`

That surface is intentionally partial.

Supported today:

- Claude
- Codex

Not supported today:

- Gemini
- Amp

Unsupported providers fail validation immediately instead of silently ignoring
the common Ollama knobs.

### Claude Semantics

Claude's common Ollama path supports two model intents:

- keep a canonical Claude model name such as `haiku` and map it to an Ollama model id
- use a direct external model id as the selected model

ASM normalizes that into Claude's Ollama backend config and the core-owned
model payload.

### Codex Semantics

Codex's common Ollama path is a direct external model route.

ASM normalizes that into:

- `provider_backend: :oss`
- `oss_provider: "ollama"`

The selected model is the direct Ollama model id.

## Example Behavior

The ASM examples use these surfaces directly.

- common and provider-native examples default to `permission_mode: :bypass`
- startup output prints the provider-native permission term and CLI flag
- `--ollama` and the related `--ollama-*` flags are only valid for Claude and Codex examples

Use `ASM.ProviderFeatures` when you need to present or gate these features in a
host application before starting a session.
