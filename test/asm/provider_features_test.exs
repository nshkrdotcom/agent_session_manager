defmodule ASM.ProviderFeaturesTest do
  use ASM.TestCase

  alias ASM.{Options, Provider, ProviderFeatures}
  alias ASM.Schema.ProviderOptions, as: ProviderOptionsSchema

  defmodule LegacyTransportSelectorStub do
    @moduledoc false
  end

  test "provider manifest exposes ollama support as a common partial feature" do
    claude = ProviderFeatures.manifest!(:claude)
    codex = ProviderFeatures.manifest!(:codex)
    gemini = ProviderFeatures.manifest!(:gemini)
    amp = ProviderFeatures.manifest!(:amp)

    assert claude.common_features.ollama.supported? == true

    assert claude.common_features.ollama.common_opts == [
             :ollama,
             :ollama_model,
             :ollama_base_url,
             :ollama_http,
             :ollama_timeout_ms
           ]

    assert claude.common_features.ollama.model_strategy == :canonical_or_direct_external

    assert claude.permission_modes.bypass_permissions.cli_excerpt ==
             "--permission-mode bypassPermissions"

    assert codex.common_features.ollama.supported? == true
    assert codex.common_features.ollama.model_strategy == :direct_external
    assert codex.common_features.ollama.compatibility.default_model == "gpt-oss:20b"

    assert codex.common_features.ollama.compatibility.acceptance ==
             :runtime_validated_external_model

    assert codex.common_features.ollama.compatibility.validated_models == ["gpt-oss:20b"]
    assert codex.permission_modes.yolo.cli_excerpt == "--dangerously-bypass-approvals-and-sandbox"

    assert gemini.common_features.ollama.supported? == false
    assert gemini.permission_modes.yolo.cli_excerpt == "--yolo"

    assert amp.common_features.ollama.supported? == false
    assert amp.permission_modes.dangerously_allow_all.cli_excerpt == "--dangerously-allow-all"
  end

  test "ASM rejects normalized auto mode for Codex while preserving native feature discovery" do
    schema = Provider.resolve!(:codex).options_schema

    assert {:error, error} =
             Options.validate([provider: :codex, permission_mode: :auto], schema)

    assert error.message =~ "Permission mode :auto is not valid for provider :codex_exec"

    assert ProviderFeatures.permission_mode!(:codex, :yolo).cli_excerpt ==
             "--dangerously-bypass-approvals-and-sandbox"
  end

  test "common ollama surface maps to Claude backend configuration" do
    schema = Provider.resolve!(:claude).options_schema

    assert {:ok, validated} =
             Options.validate(
               [
                 provider: :claude,
                 model: "haiku",
                 ollama: true,
                 ollama_model: "llama3.2",
                 ollama_base_url: "http://127.0.0.1:11434"
               ],
               schema
             )

    assert validated[:provider_backend] == :ollama
    assert validated[:model] == "haiku"
    assert validated[:anthropic_base_url] == "http://127.0.0.1:11434"
    assert validated[:anthropic_auth_token] == "ollama"
    assert validated[:external_model_overrides] == %{"haiku" => "llama3.2"}
    assert {:ok, ^validated} = ProviderOptionsSchema.validate(validated)
  end

  test "common ollama surface maps to Codex backend configuration for arbitrary local models" do
    schema = Provider.resolve!(:codex).options_schema

    assert {:ok, validated} =
             Options.validate(
               [
                 provider: :codex,
                 ollama: true,
                 ollama_model: "llama3.2",
                 ollama_base_url: "http://127.0.0.1:11434"
               ],
               schema
             )

    assert validated[:provider_backend] == :oss
    assert validated[:oss_provider] == "ollama"
    assert validated[:model] == "llama3.2"
    assert validated[:ollama_base_url] == "http://127.0.0.1:11434"
    assert {:ok, ^validated} = ProviderOptionsSchema.validate(validated)
  end

  test "common ollama surface rejects unsupported providers" do
    schema = Provider.resolve!(:gemini).options_schema

    assert {:error, error} =
             Options.validate(
               [
                 provider: :gemini,
                 ollama: true,
                 ollama_model: "llama3.2"
               ],
               schema
             )

    assert error.message =~ "does not support the common Ollama surface"
  end

  test "ASM local provider-option schemas do not absorb foreign provider keys" do
    assert {:error, {:invalid_provider_options, details}} =
             ProviderOptionsSchema.validate(
               provider: :claude,
               permission_mode: :default,
               provider_permission_mode: nil,
               cli_path: nil,
               cwd: nil,
               env: %{},
               args: [],
               ollama: false,
               ollama_model: nil,
               ollama_base_url: nil,
               ollama_http: nil,
               ollama_timeout_ms: nil,
               model_payload: nil,
               queue_limit: 1_000,
               overflow_policy: :fail_run,
               subscriber_queue_warn: 100,
               subscriber_queue_limit: 500,
               approval_timeout_ms: 120_000,
               transport_timeout_ms: 60_000,
               transport_headless_timeout_ms: 5_000,
               max_stdout_buffer_bytes: 1_048_576,
               max_stderr_buffer_bytes: 65_536,
               max_concurrent_runs: 1,
               max_queued_runs: 10,
               debug: false,
               model: "haiku",
               provider_backend: :anthropic,
               external_model_overrides: %{},
               anthropic_base_url: nil,
               anthropic_auth_token: nil,
               include_thinking: false,
               max_turns: 1,
               output_schema: %{"type" => "object"}
             )

    assert details.message =~ "output_schema"
  end

  test "provider schemas allow system prompt only where the runtime surface supports it" do
    claude_schema = Provider.resolve!(:claude).options_schema
    codex_schema = Provider.resolve!(:codex).options_schema
    gemini_schema = Provider.resolve!(:gemini).options_schema
    amp_schema = Provider.resolve!(:amp).options_schema

    assert {:ok, claude_validated} =
             Options.validate(
               [
                 provider: :claude,
                 model: "haiku",
                 system_prompt: %{type: :preset, preset: :claude_code, append: "Stay concise."},
                 append_system_prompt: "Prefer exact file paths."
               ],
               claude_schema
             )

    assert claude_validated[:system_prompt] == %{
             type: :preset,
             preset: :claude_code,
             append: "Stay concise."
           }

    assert claude_validated[:append_system_prompt] == "Prefer exact file paths."

    assert {:ok, codex_validated} =
             Options.validate(
               [
                 provider: :codex,
                 model: "gpt-5.4",
                 system_prompt: "Respect repository instructions."
               ],
               codex_schema
             )

    assert codex_validated[:system_prompt] == "Respect repository instructions."

    assert {:ok, gemini_validated} =
             Options.validate(
               [provider: :gemini, model: "gemini-2.5-pro", system_prompt: "Be concise."],
               gemini_schema
             )

    assert gemini_validated[:system_prompt] == "Be concise."

    assert {:error, amp_error} =
             Options.validate(
               [provider: :amp, model: "amp-1", system_prompt: "Unsupported"],
               amp_schema
             )

    assert amp_error.message =~ "unknown options [:system_prompt]"
  end

  test "claude leaves max_turns unset by default and amp rejects it entirely" do
    claude_schema = Provider.resolve!(:claude).options_schema
    amp_schema = Provider.resolve!(:amp).options_schema

    assert {:ok, claude_validated} =
             Options.validate([provider: :claude, model: "haiku"], claude_schema)

    assert claude_validated[:max_turns] == nil
    assert {:ok, ^claude_validated} = ProviderOptionsSchema.validate(claude_validated)

    assert {:error, amp_error} =
             Options.validate([provider: :amp, model: "amp-1", max_turns: 2], amp_schema)

    assert amp_error.message =~ "unknown options [:max_turns]"
  end

  test "codex rejects conflicting model and ollama_model values" do
    schema = Provider.resolve!(:codex).options_schema

    assert {:error, error} =
             Options.validate(
               [
                 provider: :codex,
                 model: "gpt-5.4",
                 ollama: true,
                 ollama_model: "llama3.2"
               ],
               schema
             )

    assert error.message =~ "conflicts with"
    assert error.message =~ ":ollama_model"
  end

  test "finalize_provider_opts rejects legacy transport-selector overrides" do
    assert {:error, error} =
             Options.finalize_provider_opts(:claude,
               model: "haiku",
               transport_module: LegacyTransportSelectorStub
             )

    assert error.message =~ "no longer accepts legacy transport-selector overrides"
  end
end
