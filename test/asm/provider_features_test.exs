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

  test "provider lane capability manifests use support states across all four SDK providers" do
    assert ProviderFeatures.support_states() == [
             :common,
             :native,
             :sdk_local,
             :event_only,
             :unsupported,
             :planned
           ]

    codex_app_server = ProviderFeatures.lane_manifest!(:codex, :sdk_app_server)
    assert codex_app_server.composition_mode == :native_extension
    assert codex_app_server.capabilities.host_tools.support_state == :native
    assert codex_app_server.capabilities.host_tools.supported? == true
    assert codex_app_server.capabilities.host_tools.provider_native? == true
    assert :host_tools in codex_app_server.capabilities.host_tools.asm_option_keys
    assert :dynamic_tools in codex_app_server.capabilities.host_tools.provider_native_option_keys
    assert :host_tool_requested in codex_app_server.capabilities.host_tools.event_kinds
    assert codex_app_server.capabilities.app_server.support_state == :native
    assert codex_app_server.capabilities.sandbox_policy.support_state == :native

    codex_core = ProviderFeatures.lane_manifest!(:codex, :core)
    assert codex_core.composition_mode == :common_surface_only
    assert codex_core.capabilities.host_tools.support_state == :event_only
    assert codex_core.capabilities.app_server.support_state == :unsupported
    assert codex_core.capabilities.workspace_context.support_state == :common

    claude_sdk = ProviderFeatures.lane_manifest!(:claude, :sdk)
    assert claude_sdk.composition_mode == :native_extension
    assert claude_sdk.capabilities.host_tools.support_state == :unsupported
    assert claude_sdk.capabilities.provider_control.support_state == :native
    assert claude_sdk.capabilities.app_server.support_state == :unsupported
    refute :dynamic_tools in claude_sdk.capabilities.host_tools.provider_native_option_keys

    for provider <- [:amp, :gemini] do
      manifest = ProviderFeatures.lane_manifest!(provider, :sdk)

      assert manifest.composition_mode == :common_surface_only
      assert manifest.native_namespaces == []
      assert manifest.capabilities.host_tools.support_state == :unsupported
      assert manifest.capabilities.host_tools.supported? == false
      assert manifest.capabilities.app_server.support_state == :unsupported
      assert manifest.capabilities.sandbox_policy.support_state in [:unsupported, :sdk_local]
      refute :dynamic_tools in manifest.capabilities.host_tools.provider_native_option_keys
    end
  end

  test "host tools are not admitted as an all-provider common ASM capability" do
    for provider <- [:claude, :codex, :gemini, :amp],
        lane <- Map.keys(ProviderFeatures.manifest!(provider).lanes) do
      manifest = ProviderFeatures.lane_manifest!(provider, lane)
      host_tools = manifest.capabilities.host_tools

      refute host_tools.support_state == :common

      if provider == :codex and lane == :sdk_app_server do
        assert host_tools.support_state == :native
        assert host_tools.provider_native? == true
      else
        assert host_tools.support_state in [:event_only, :unsupported]
        refute host_tools.provider_native? && host_tools.supported?
      end
    end
  end

  test "sandbox policy discovery does not expose a common ASM sandbox control" do
    for provider <- [:claude, :codex, :gemini, :amp],
        lane <- Map.keys(ProviderFeatures.manifest!(provider).lanes) do
      manifest = ProviderFeatures.lane_manifest!(provider, lane)
      sandbox_policy = manifest.capabilities.sandbox_policy

      refute sandbox_policy.support_state == :common
      refute sandbox_policy.common_surface? == true
    end
  end

  test "unsupported provider capabilities fail with explicit provider lane and capability context" do
    assert :ok = ProviderFeatures.require_capability(:codex, :sdk_app_server, :host_tools)

    assert {:error, error} = ProviderFeatures.require_capability(:amp, :sdk, :host_tools)
    assert error.kind == :config_invalid
    assert error.domain == :provider
    assert error.message =~ ":amp"
    assert error.message =~ ":sdk"
    assert error.message =~ ":host_tools"
    assert error.message =~ "unsupported"

    assert {:error, error} = ProviderFeatures.require_capability(:gemini, :sdk, :app_server)
    assert error.message =~ ":gemini"
    assert error.message =~ ":app_server"
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
               [
                 provider: :gemini,
                 model: "gemini-3.1-flash-lite-preview",
                 system_prompt: "Be concise."
               ],
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
