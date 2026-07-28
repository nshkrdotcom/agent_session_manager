defmodule ASM.Provider do
  @moduledoc """
  Provider definition data used by the backend registry.
  """

  alias ASM.Error
  alias ASM.Provider.ExampleSupport
  alias ASM.Provider.Profile
  alias CliSubprocessCore.ProviderFeatures, as: CoreProviderFeatures

  @enforce_keys [
    :name,
    :display_name,
    :core_profile,
    :example_support,
    :options_schema,
    :profile,
    :feature_manifest
  ]
  defstruct [
    :name,
    :display_name,
    :core_profile,
    :sdk_runtime,
    :example_support,
    :options_schema,
    :profile,
    :feature_manifest,
    aliases: [],
    metadata: %{}
  ]

  @type provider_name ::
          :amp | :antigravity | :claude | :codex | :codex_exec | :cursor | atom()

  @provider_names_by_string %{
    "amp" => :amp,
    "antigravity" => :antigravity,
    "claude" => :claude,
    "codex" => :codex,
    "codex_exec" => :codex,
    "cursor" => :cursor
  }

  @type t :: %__MODULE__{
          name: provider_name(),
          display_name: String.t(),
          core_profile: module(),
          sdk_runtime: module() | nil,
          example_support: ExampleSupport.t(),
          options_schema: keyword(),
          profile: Profile.t(),
          feature_manifest: map(),
          aliases: [provider_name()],
          metadata: map()
        }

  @spec supported_providers() :: [provider_name()]
  def supported_providers, do: Map.keys(providers())

  @spec example_support(t() | provider_name()) :: {:ok, ExampleSupport.t()} | {:error, Error.t()}
  def example_support(provider_or_name) do
    with {:ok, %__MODULE__{} = provider} <- resolve(provider_or_name) do
      {:ok, provider.example_support}
    end
  end

  @spec example_support!(t() | provider_name()) :: ExampleSupport.t()
  def example_support!(provider_or_name) do
    case example_support(provider_or_name) do
      {:ok, %ExampleSupport{} = example_support} ->
        example_support

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @spec feature_manifest(t() | provider_name()) :: {:ok, map()} | {:error, Error.t()}
  def feature_manifest(provider_or_name) do
    with {:ok, %__MODULE__{} = provider} <- resolve(provider_or_name) do
      {:ok, provider.feature_manifest}
    end
  end

  @spec feature_manifest!(t() | provider_name()) :: map()
  def feature_manifest!(provider_or_name) do
    case feature_manifest(provider_or_name) do
      {:ok, manifest} ->
        manifest

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @spec supports_feature?(t() | provider_name(), atom()) :: boolean()
  def supports_feature?(provider_or_name, feature) when is_atom(feature) do
    case feature_manifest(provider_or_name) do
      {:ok, manifest} ->
        get_in(manifest, [feature, :supported?]) == true

      {:error, _error} ->
        false
    end
  end

  @spec resolve(t() | provider_name() | String.t()) :: {:ok, t()} | {:error, Error.t()}
  def resolve(%__MODULE__{} = provider), do: {:ok, provider}

  def resolve(name) when is_atom(name) do
    case find_provider(name) do
      {:ok, provider} ->
        {:ok, provider}

      :error ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "Unknown provider: #{inspect(name)}",
           cause: %{provider: name}
         )}
    end
  end

  def resolve(name) when is_binary(name) do
    case provider_name_from_string(name) do
      {:ok, provider_name} ->
        resolve(provider_name)

      :error ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "Unknown provider: #{inspect(name)}",
           cause: %{provider: name}
         )}
    end
  end

  def resolve(other) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "Provider must be an atom or %ASM.Provider{}, got: #{inspect(other)}",
       cause: %{provider: other}
     )}
  end

  @spec resolve!(t() | provider_name()) :: t()
  def resolve!(provider_or_name) do
    case resolve(provider_or_name) do
      {:ok, provider} ->
        provider

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  defp find_provider(name) do
    case Map.fetch(providers(), normalize_name(name)) do
      {:ok, provider} -> {:ok, provider}
      :error -> find_alias(name)
    end
  end

  defp find_alias(name) do
    Enum.find_value(providers(), :error, fn {_id, provider} ->
      if name in provider.aliases do
        {:ok, provider}
      else
        false
      end
    end)
  end

  defp providers do
    %{
      claude: %__MODULE__{
        name: :claude,
        display_name: "Claude CLI",
        core_profile: CliSubprocessCore.ProviderProfiles.Claude,
        sdk_runtime: :"Elixir.ClaudeAgentSDK.Runtime.CLI",
        example_support: %ExampleSupport{
          cli_command: "claude",
          cli_path_env: "CLAUDE_CLI_PATH",
          install_hint: "npm install -g @anthropic-ai/claude-code",
          model_env: "ASM_CLAUDE_MODEL",
          example_default_model: nil,
          sdk_app: :claude_agent_sdk,
          sdk_repo_dir: "claude_agent_sdk",
          sdk_root_env: "CLAUDE_AGENT_SDK_ROOT"
        },
        options_schema: ASM.Options.Claude.schema(),
        feature_manifest: feature_manifest_for(:claude),
        profile:
          Profile.new!(
            max_concurrent_runs: 1,
            max_queued_runs: 10
          )
      },
      codex: %__MODULE__{
        name: :codex,
        display_name: "Codex CLI",
        core_profile: CliSubprocessCore.ProviderProfiles.Codex,
        sdk_runtime: :"Elixir.Codex.Runtime.Exec",
        example_support: %ExampleSupport{
          cli_command: "codex",
          cli_path_env: "CODEX_PATH",
          install_hint: "npm install -g @openai/codex",
          model_env: "ASM_CODEX_MODEL",
          example_default_model: nil,
          sdk_app: :codex_sdk,
          sdk_repo_dir: "codex_sdk",
          sdk_root_env: "CODEX_SDK_ROOT",
          sdk_cli_env: "CODEX_PATH"
        },
        options_schema: ASM.Options.Codex.schema(),
        feature_manifest: feature_manifest_for(:codex),
        aliases: [:codex_exec],
        profile:
          Profile.new!(
            max_concurrent_runs: 1,
            max_queued_runs: 10
          )
      },
      amp: %__MODULE__{
        name: :amp,
        display_name: "Amp CLI",
        core_profile: CliSubprocessCore.ProviderProfiles.Amp,
        sdk_runtime: :"Elixir.AmpSdk.Runtime.CLI",
        example_support: %ExampleSupport{
          cli_command: "amp",
          cli_path_env: "AMP_CLI_PATH",
          install_hint: "npm install -g @sourcegraph/amp",
          model_env: "ASM_AMP_MODEL",
          example_default_model: nil,
          sdk_app: :amp_sdk,
          sdk_repo_dir: "amp_sdk",
          sdk_root_env: "AMP_SDK_ROOT",
          sdk_cli_env: "AMP_CLI_PATH"
        },
        options_schema: ASM.Options.Amp.schema(),
        feature_manifest: feature_manifest_for(:amp),
        profile:
          Profile.new!(
            max_concurrent_runs: 1,
            max_queued_runs: 10
          )
      },
      cursor: %__MODULE__{
        name: :cursor,
        display_name: "Cursor Agent CLI",
        core_profile: CliSubprocessCore.ProviderProfiles.Cursor,
        sdk_runtime: :"Elixir.CursorCliSdk.Runtime.CLI",
        example_support: %ExampleSupport{
          cli_command: "agent",
          cli_path_env: "CURSOR_CLI_PATH",
          install_hint: "https://cursor.com/docs/cli/overview",
          model_env: "ASM_CURSOR_MODEL",
          example_default_model: nil,
          sdk_app: :cursor_cli_sdk,
          sdk_repo_dir: "cursor_cli_sdk",
          sdk_root_env: "CURSOR_CLI_SDK_ROOT",
          sdk_cli_env: "CURSOR_CLI_PATH"
        },
        options_schema: ASM.Options.Cursor.schema(),
        feature_manifest: feature_manifest_for(:cursor),
        profile:
          Profile.new!(
            max_concurrent_runs: 1,
            max_queued_runs: 10
          )
      },
      antigravity: %__MODULE__{
        name: :antigravity,
        display_name: "Antigravity CLI",
        core_profile: CliSubprocessCore.ProviderProfiles.Antigravity,
        sdk_runtime: :"Elixir.AntigravityCliSdk.Runtime.CLI",
        example_support: %ExampleSupport{
          cli_command: "agy",
          cli_path_env: "ANTIGRAVITY_CLI_PATH",
          install_hint: "Install the Antigravity CLI agent binary",
          model_env: "ASM_ANTIGRAVITY_MODEL",
          example_default_model: nil,
          sdk_app: :antigravity_cli_sdk,
          sdk_repo_dir: "antigravity_cli_sdk",
          sdk_root_env: "ANTIGRAVITY_CLI_SDK_ROOT",
          sdk_cli_env: "ANTIGRAVITY_CLI_PATH"
        },
        options_schema: ASM.Options.Antigravity.schema(),
        feature_manifest: feature_manifest_for(:antigravity),
        profile:
          Profile.new!(
            max_concurrent_runs: 1,
            max_queued_runs: 10
          )
      }
    }
  end

  defp normalize_name(:codex_exec), do: :codex
  defp normalize_name(name), do: name

  defp provider_name_from_string(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> then(&Map.fetch(@provider_names_by_string, &1))
  end

  # ASM owns no second capability catalog: every entry is the
  # `cli_subprocess_core` partial-feature manifest plus the ASM option names
  # that activate it. A provider the core catalog does not describe is
  # reported as unsupported rather than omitted, so callers can query it.
  defp feature_manifest_for(provider) when is_atom(provider) do
    %{
      ollama:
        common_feature_manifest(provider, :ollama, [
          :ollama,
          :ollama_model,
          :ollama_base_url,
          :ollama_http,
          :ollama_timeout_ms
        ]),
      structured_output: common_feature_manifest(provider, :structured_output, [:output_schema]),
      completion_only: common_feature_manifest(provider, :completion_only, [:completion_only])
    }
  end

  defp common_feature_manifest(provider, feature, common_opts)
       when is_atom(provider) and is_atom(feature) and is_list(common_opts) do
    provider
    |> CoreProviderFeatures.partial_feature(feature)
    |> case do
      {:ok, manifest} -> manifest
      :error -> undeclared_partial_feature(provider, feature)
    end
    |> Map.merge(%{common_surface: true, common_opts: common_opts})
  end

  defp undeclared_partial_feature(provider, feature) do
    %{
      supported?: false,
      activation: nil,
      model_strategy: nil,
      compatibility: nil,
      notes: [
        "#{inspect(provider)} declares no #{inspect(feature)} partial feature in the shared CLI core catalog."
      ]
    }
  end
end
