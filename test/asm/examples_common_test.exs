defmodule ASM.Examples.CommonTest do
  use ASM.SerialTestCase

  alias ASM.Examples.Common
  alias ASM.{Options, Provider}
  alias CliSubprocessCore.ModelRegistry.Selection

  @script_name "live_query.exs"
  @description "Run a one-off ASM.query/3 call against the selected provider."
  @default_prompt "Reply with exactly: LIVE_QUERY_OK"
  @cli_path "/bin/echo"

  setup do
    env_vars = [
      "AMP_SDK_ROOT",
      "AMP_CLI_PATH",
      "ASM_PERMISSION_MODE",
      "ASM_AMP_MODEL",
      "ASM_CLAUDE_MODEL",
      "ASM_CODEX_MODEL",
      "ASM_GEMINI_MODEL",
      "CLAUDE_AGENT_SDK_ROOT",
      "CLAUDE_CLI_PATH",
      "CODEX_SDK_ROOT",
      "CODEX_PATH",
      "GEMINI_CLI_PATH",
      "GEMINI_CLI_SDK_ROOT"
    ]

    original =
      Map.new(env_vars, fn key ->
        {key, System.get_env(key)}
      end)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "core-lane common examples do not resolve SDK roots" do
    sdk_root = Path.expand("../../../codex_sdk", __DIR__)
    System.put_env("CODEX_SDK_ROOT", sdk_root)

    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "codex", "--cli-path", @cli_path],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.provider == :codex
    assert config.lane == :core
    assert config.sdk_root == nil
    assert config.session_opts[:cli_path] == @cli_path
  end

  test "provider CLI env remains resolver-owned for common examples" do
    System.put_env("GEMINI_CLI_PATH", "gemini")

    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "gemini"],
               @script_name,
               @description,
               @default_prompt
             )

    refute Keyword.has_key?(config.session_opts, :cli_path)
  end

  test "gemini examples default to the current flash-lite preview when no explicit model is provided" do
    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "gemini"],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.session_opts[:model] == "gemini-3.1-flash-lite-preview"
  end

  test "examples default to bypass mode with provider-native permission metadata" do
    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "codex"],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.provider_opts[:permission_mode] == :bypass
    assert config.provider_opts[:provider_permission_mode] == :yolo
    assert config.permission_source == :example_default_bypass
  end

  test "exact_text_match?/2 trims surrounding whitespace but still enforces exact content" do
    assert Common.exact_text_match?("  LIVE_QUERY_OK\n", "LIVE_QUERY_OK")
    refute Common.exact_text_match?("LIVE_QUERY_OK extra", "LIVE_QUERY_OK")
    refute Common.exact_text_match?(nil, "LIVE_QUERY_OK")
  end

  test "examples record when permission mode comes from the CLI flag" do
    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "amp", "--permission-mode", "plan"],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.provider_opts[:permission_mode] == :plan
    assert config.provider_opts[:provider_permission_mode] == :plan
    assert config.permission_source == :cli_flag
  end

  test "danger-full-access acts as the example alias for bypass mode" do
    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "codex", "--danger-full-access"],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.provider_opts[:permission_mode] == :bypass
    assert config.provider_opts[:provider_permission_mode] == :yolo
    assert config.permission_source == :danger_full_access_flag
  end

  test "danger-full-access rejects conflicting non-bypass permission modes" do
    assert {:usage, 1, output} =
             Common.build_example_config(
               ["--provider", "claude", "--danger-full-access", "--permission-mode", "plan"],
               @script_name,
               @description,
               @default_prompt
             )

    assert String.contains?(
             output,
             "--danger-full-access is the example alias for --permission-mode bypass"
           )
  end

  test "common example parser accepts the Ollama surface" do
    assert {:ok, config} =
             Common.build_example_config(
               [
                 "--provider",
                 "claude",
                 "--ollama",
                 "--model",
                 "haiku",
                 "--ollama-model",
                 "llama3.2"
               ],
               @script_name,
               @description,
               @default_prompt,
               provider_opts_builder: fn provider, session_opts ->
                 finalized_provider_opts(provider, session_opts, claude_ollama_payload())
               end
             )

    payload = Keyword.fetch!(config.provider_opts, :model_payload)

    assert payload.provider_backend == :ollama
    assert payload.requested_model == "haiku"
    assert payload.resolved_model == "llama3.2"
    assert payload.env_overrides["ANTHROPIC_AUTH_TOKEN"] == "ollama"
  end

  test "common example parser injects ssh execution_surface metadata" do
    assert {:ok, config} =
             Common.build_example_config(
               [
                 "--provider",
                 "codex",
                 "--ssh-host",
                 "builder@example.internal",
                 "--ssh-port",
                 "2222",
                 "--ssh-identity-file",
                 "./tmp/id_ed25519"
               ],
               @script_name,
               @description,
               @default_prompt
             )

    execution_surface = Keyword.fetch!(config.session_opts, :execution_surface)

    assert execution_surface.surface_kind == :ssh_exec
    assert execution_surface.transport_options[:destination] == "example.internal"
    assert execution_surface.transport_options[:ssh_user] == "builder"
    assert execution_surface.transport_options[:port] == 2222

    assert String.contains?(
             execution_surface.transport_options[:identity_file],
             "/tmp/id_ed25519"
           )

    assert execution_surface.transport_options[:ssh_options]["BatchMode"] == "yes"
    assert execution_surface.transport_options[:ssh_options]["ConnectTimeout"] == 10
  end

  test "common example parser rejects orphan ssh flags without a host" do
    assert {:usage, 1, output} =
             Common.build_example_config(
               ["--provider", "claude", "--ssh-user", "builder"],
               @script_name,
               @description,
               @default_prompt
             )

    assert String.contains?(output, "SSH example flags require --ssh-host")
  end

  test "common example parser accepts the Codex Ollama surface for arbitrary local models" do
    assert {:ok, config} =
             Common.build_example_config(
               [
                 "--provider",
                 "codex",
                 "--ollama",
                 "--ollama-model",
                 "llama3.2"
               ],
               @script_name,
               @description,
               @default_prompt,
               provider_opts_builder: fn provider, session_opts ->
                 finalized_provider_opts(provider, session_opts, codex_ollama_payload())
               end
             )

    payload = Keyword.fetch!(config.provider_opts, :model_payload)

    assert payload.provider_backend == :oss
    assert payload.backend_metadata["oss_provider"] == "ollama"
    assert payload.resolved_model == "llama3.2"
  end

  test "exact-output smoke targets stay strict for validated Codex Ollama models" do
    config =
      smoke_config(%{
        requested_model: "gpt-oss:20b",
        resolved_model: "gpt-oss:20b",
        backend_metadata: %{
          "oss_provider" => "ollama",
          "support_tier" => "validated_default"
        }
      })

    assert Common.exact_output_smoke_target?(config)
    assert Common.exact_output_smoke_skip_reason(config) == nil
  end

  test "exact-output smoke targets skip runtime-validated Codex Ollama models" do
    config =
      smoke_config(%{
        requested_model: "llama3.2",
        resolved_model: "llama3.2",
        model_family: "llama",
        backend_metadata: %{
          "oss_provider" => "ollama",
          "support_tier" => "runtime_validated_only"
        }
      })

    refute Common.exact_output_smoke_target?(config)

    assert String.contains?(Common.exact_output_smoke_skip_reason(config), "llama3.2")

    assert String.contains?(
             Common.exact_output_smoke_skip_reason(config),
             "runtime_validated_only"
           )
  end

  test "sdk lane resolves SDK root from provider env" do
    sdk_root = Path.expand("../../../codex_sdk", __DIR__)
    System.put_env("CODEX_SDK_ROOT", sdk_root)

    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "codex", "--lane", "sdk", "--cli-path", @cli_path],
               @script_name,
               @description,
               @default_prompt
             )

    assert config.lane == :sdk
    assert config.sdk_root == sdk_root
  end

  test "provider-native examples resolve SDK roots even on core lane" do
    sdk_root = Path.expand("../../../gemini_cli_sdk", __DIR__)
    System.put_env("GEMINI_CLI_SDK_ROOT", sdk_root)

    assert {:ok, config} =
             Common.build_example_config(
               ["--provider", "gemini", "--cli-path", @cli_path],
               "provider_gemini_session_resume.exs",
               "Provider-native Gemini example.",
               "Reply with exactly: GEMINI_OK",
               provider_sdk?: true
             )

    assert config.provider == :gemini
    assert config.lane == :core
    assert config.sdk_root == sdk_root
  end

  test "missing provider returns informational usage without building config" do
    assert {:usage, 0, output} =
             Common.build_example_config([], @script_name, @description, @default_prompt)

    assert String.contains?(output, "did not run because no provider was selected")
    assert String.contains?(output, "--provider claude|gemini|codex|amp")
  end

  test "unsupported provider returns usage error" do
    assert {:usage, 1, output} =
             Common.build_example_config(
               ["--provider", "unknown"],
               @script_name,
               @description,
               @default_prompt
             )

    assert String.contains?(output, "unsupported provider")
    assert String.contains?(output, "Usage:")
  end

  test "invalid lane returns usage error instead of halting the caller" do
    assert {:usage, 1, output} =
             Common.build_example_config(
               ["--provider", "codex", "--lane", "wrong", "--cli-path", @cli_path],
               @script_name,
               @description,
               @default_prompt
             )

    assert String.contains?(output, "unsupported lane")
    assert String.contains?(output, "Usage:")
  end

  test "sdk_bridge_opts drops orchestration-only lane metadata" do
    config = %Common{
      provider: :codex,
      prompt: @default_prompt,
      lane: :core,
      sdk_root: nil,
      session_opts: [provider: :codex, lane: :core, cli_path: @cli_path, model: "gpt-5.4"],
      provider_opts: [
        provider: :codex,
        cli_path: @cli_path,
        model: "gpt-5.4",
        permission_mode: :bypass,
        provider_permission_mode: :yolo
      ],
      permission_source: :example_default_bypass
    }

    assert Common.sdk_bridge_opts(config) == [
             provider: :codex,
             cli_path: @cli_path,
             model: "gpt-5.4",
             permission_mode: :bypass,
             provider_permission_mode: :yolo
           ]
  end

  defp smoke_config(payload_attrs) when is_map(payload_attrs) do
    payload =
      Selection.new(
        Map.merge(
          %{
            provider: :codex,
            requested_model: "gpt-oss:20b",
            resolved_model: "gpt-oss:20b",
            resolution_source: :explicit,
            reasoning: "high",
            reasoning_effort: nil,
            normalized_reasoning_effort: nil,
            model_family: "gpt-oss",
            catalog_version: nil,
            visibility: :public,
            provider_backend: :oss,
            model_source: :external,
            env_overrides: %{},
            settings_patch: %{},
            backend_metadata: %{"oss_provider" => "ollama", "support_tier" => "validated_default"},
            errors: []
          },
          payload_attrs
        )
      )

    %Common{
      provider: :codex,
      prompt: @default_prompt,
      session_opts: [],
      provider_opts: [model_payload: payload],
      lane: :core,
      sdk_root: nil,
      permission_source: :example_default_bypass
    }
  end

  defp finalized_provider_opts(provider, session_opts, model_payload)
       when is_atom(provider) and is_list(session_opts) do
    provider_schema = Provider.resolve!(provider).options_schema

    with {:ok, validated} <-
           Options.validate(Keyword.drop(session_opts, [:lane]), provider_schema) do
      provider
      |> Options.finalize_provider_opts(
        validated
        |> Keyword.delete(:provider)
        |> Keyword.put(:model_payload, model_payload)
      )
    end
  end

  defp claude_ollama_payload do
    Selection.new(%{
      provider: :claude,
      requested_model: "haiku",
      resolved_model: "llama3.2",
      resolution_source: :explicit,
      reasoning: nil,
      reasoning_effort: nil,
      normalized_reasoning_effort: nil,
      model_family: "llama",
      catalog_version: nil,
      visibility: :public,
      provider_backend: :ollama,
      model_source: :external,
      env_overrides: %{
        "ANTHROPIC_AUTH_TOKEN" => "ollama",
        "ANTHROPIC_API_KEY" => "",
        "ANTHROPIC_BASE_URL" => "http://localhost:11434"
      },
      settings_patch: %{},
      backend_metadata: %{"external_model" => "llama3.2"},
      errors: []
    })
  end

  defp codex_ollama_payload do
    Selection.new(%{
      provider: :codex,
      requested_model: "llama3.2",
      resolved_model: "llama3.2",
      resolution_source: :explicit,
      reasoning: "high",
      reasoning_effort: nil,
      normalized_reasoning_effort: nil,
      model_family: "llama",
      catalog_version: nil,
      visibility: :public,
      provider_backend: :oss,
      model_source: :external,
      env_overrides: %{"CODEX_OSS_BASE_URL" => "http://localhost:11434/v1"},
      settings_patch: %{},
      backend_metadata: %{
        "oss_provider" => "ollama",
        "external_model" => "llama3.2",
        "support_tier" => "runtime_validated_only"
      },
      errors: []
    })
  end
end
