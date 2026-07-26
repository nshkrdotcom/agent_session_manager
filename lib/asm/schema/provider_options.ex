defmodule ASM.Schema.ProviderOptions do
  @moduledoc """
  ASM-owned schema validation for provider option maps and provider profile
  limits.
  """

  alias ASM.Schema
  alias CliSubprocessCore.Schema.Conventions

  @providers [:amp, :antigravity, :claude, :codex, :codex_exec, :cursor]
  @permission_modes [:default, :auto, :bypass, :plan]
  @overflow_policies [:fail_run, :drop_oldest, :block]

  @profile_schema Zoi.map(
                    %{
                      max_concurrent_runs:
                        Zoi.default(
                          Zoi.optional(Zoi.nullish(Zoi.integer() |> Zoi.min(1))),
                          1
                        ),
                      max_queued_runs:
                        Zoi.default(
                          Zoi.optional(Zoi.nullish(Zoi.integer() |> Zoi.min(0))),
                          10
                        )
                    },
                    unrecognized_keys: :error
                  )

  @common_fields %{
    provider: Conventions.enum(@providers),
    permission_mode: Conventions.optional_enum(@permission_modes),
    provider_permission_mode: Conventions.optional_any(),
    cli_path: Conventions.optional_trimmed_string(),
    cwd: Conventions.optional_trimmed_string(),
    env: Zoi.optional(Zoi.nullish(Conventions.any_map())),
    args: Zoi.array(Conventions.trimmed_string() |> Zoi.min(1)),
    ollama: Zoi.boolean(),
    ollama_model: Conventions.optional_trimmed_string(),
    ollama_base_url: Conventions.optional_trimmed_string(),
    ollama_http: Zoi.optional(Zoi.nullish(Zoi.boolean())),
    ollama_timeout_ms: Zoi.optional(Zoi.nullish(Zoi.integer() |> Zoi.min(1))),
    # Normalized structured-output schema. Common at the option layer and
    # gated per provider by the :structured_output partial feature; the CLI
    # flag spelling stays in cli_subprocess_core.
    output_schema: Zoi.optional(Zoi.nullish(Conventions.any_map())),
    model_payload: Conventions.optional_any(),
    queue_limit: Zoi.integer() |> Zoi.min(1),
    overflow_policy: Conventions.enum(@overflow_policies),
    subscriber_queue_warn: Zoi.integer() |> Zoi.min(0),
    subscriber_queue_limit: Zoi.integer() |> Zoi.min(1),
    approval_timeout_ms: Zoi.integer() |> Zoi.min(1),
    transport_timeout_ms: Zoi.integer() |> Zoi.min(1),
    transport_headless_timeout_ms:
      Zoi.any() |> Zoi.transform({__MODULE__, :normalize_timeout_or_infinity, []}),
    max_stdout_buffer_bytes: Zoi.integer() |> Zoi.min(1),
    max_stderr_buffer_bytes: Zoi.integer() |> Zoi.min(1),
    max_concurrent_runs: Zoi.integer() |> Zoi.min(1),
    max_queued_runs: Zoi.integer() |> Zoi.min(0),
    debug: Zoi.boolean(),
    # Allow a model newer than the shared cli_subprocess_core registry to
    # pass through to the CLI as-is (default false = require a registered
    # model). Common across every provider since ASM.Options.normalize_model_input/3
    # threads this to the shared registry's `allow_unknown` resolution
    # regardless of provider.
    allow_unknown_model: Zoi.optional(Zoi.nullish(Zoi.boolean()))
  }

  @claude_fields %{
    model: Conventions.optional_trimmed_string(),
    system_prompt: Conventions.optional_any(),
    append_system_prompt: Conventions.optional_trimmed_string(),
    provider_backend: Conventions.optional_any(),
    external_model_overrides: Zoi.optional(Zoi.nullish(Conventions.any_map())),
    anthropic_base_url: Conventions.optional_trimmed_string(),
    anthropic_auth_token: Conventions.optional_trimmed_string(),
    include_thinking: Zoi.boolean(),
    completion_only: Zoi.boolean(),
    max_turns: Zoi.optional(Zoi.nullish(Zoi.integer() |> Zoi.min(1)))
  }

  @codex_fields %{
    model: Conventions.optional_trimmed_string(),
    system_prompt: Conventions.optional_trimmed_string(),
    reasoning_effort: Conventions.optional_any(),
    provider_backend: Conventions.optional_any(),
    model_provider: Conventions.optional_trimmed_string(),
    oss_provider: Conventions.optional_trimmed_string(),
    skip_git_repo_check: Zoi.boolean(),
    completion_only: Zoi.boolean(),
    app_server: Zoi.boolean(),
    host_tools: Zoi.array(Conventions.optional_any()),
    dynamic_tools: Zoi.array(Conventions.optional_any()),
    additional_directories: Zoi.array(Conventions.trimmed_string() |> Zoi.min(1))
  }

  @amp_fields %{
    model: Conventions.optional_trimmed_string(),
    mode: Conventions.trimmed_string() |> Zoi.min(1),
    include_thinking: Zoi.boolean(),
    permissions: Zoi.optional(Zoi.nullish(Conventions.any_map())),
    mcp_config: Zoi.optional(Zoi.nullish(Conventions.any_map())),
    tools: Zoi.array(Conventions.trimmed_string() |> Zoi.min(1))
  }

  @antigravity_fields %{
    model: Conventions.optional_trimmed_string(),
    sandbox: Zoi.boolean(),
    dangerously_skip_permissions: Zoi.boolean(),
    conversation: Conventions.optional_trimmed_string(),
    continue: Zoi.boolean(),
    add_dirs: Zoi.array(Conventions.trimmed_string() |> Zoi.min(1)),
    print_timeout: Conventions.optional_trimmed_string(),
    log_file: Conventions.optional_trimmed_string()
  }

  @cursor_fields %{
    model: Conventions.optional_trimmed_string(),
    mode: Conventions.optional_any(),
    sandbox: Conventions.optional_any(),
    approve_mcps: Zoi.boolean(),
    worktree: Conventions.optional_any(),
    worktree_base: Conventions.optional_trimmed_string(),
    skip_worktree_setup: Zoi.boolean(),
    plugin_dirs: Zoi.array(Conventions.trimmed_string() |> Zoi.min(1)),
    headers: Zoi.array(Conventions.optional_any())
  }

  @spec validate(keyword() | map()) ::
          {:ok, keyword() | map()}
          | {:error, {:invalid_provider_options, CliSubprocessCore.Schema.error_detail()}}
  def validate(opts) when is_list(opts) or is_map(opts) do
    map = Enum.into(opts, %{})

    with {:ok, %{provider: provider}} <-
           Schema.parse(
             Zoi.map(%{provider: Conventions.enum(@providers)}),
             map,
             :invalid_provider_options
           ),
         {:ok, _parsed} <- Schema.parse(schema_for(provider), map, :invalid_provider_options) do
      {:ok, opts}
    end
  end

  @spec parse_profile(keyword() | map()) ::
          {:ok, map()}
          | {:error, {:invalid_provider_profile, CliSubprocessCore.Schema.error_detail()}}
  def parse_profile(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Enum.into(attrs, %{})
    Schema.parse(@profile_schema, attrs, :invalid_provider_profile)
  end

  @spec profile_schema() :: Zoi.schema()
  def profile_schema, do: @profile_schema

  @doc false
  def normalize_timeout_or_infinity(value, opts),
    do: normalize_timeout_or_infinity(value, [], opts)

  @doc false
  def normalize_timeout_or_infinity(value, _args, _opts) do
    cond do
      is_integer(value) and value > 0 -> {:ok, value}
      value == :infinity -> {:ok, :infinity}
      true -> {:error, "expected a positive integer or :infinity"}
    end
  end

  defp schema_for(:claude),
    do: Zoi.map(Map.merge(@common_fields, @claude_fields), unrecognized_keys: :error)

  defp schema_for(:codex),
    do: Zoi.map(Map.merge(@common_fields, @codex_fields), unrecognized_keys: :error)

  defp schema_for(:codex_exec),
    do: Zoi.map(Map.merge(@common_fields, @codex_fields), unrecognized_keys: :error)

  defp schema_for(:amp),
    do: Zoi.map(Map.merge(@common_fields, @amp_fields), unrecognized_keys: :error)

  defp schema_for(:antigravity),
    do: Zoi.map(Map.merge(@common_fields, @antigravity_fields), unrecognized_keys: :error)

  defp schema_for(:cursor),
    do: Zoi.map(Map.merge(@common_fields, @cursor_fields), unrecognized_keys: :error)
end
