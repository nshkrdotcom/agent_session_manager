defmodule ASM.ProviderFeaturesTest do
  use ASM.TestCase

  alias ASM.{Options, Provider, ProviderFeatures}

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
               transport_module: ClaudeAgentSDK.Transport
             )

    assert error.message =~ "no longer accepts legacy transport-selector overrides"
  end
end
