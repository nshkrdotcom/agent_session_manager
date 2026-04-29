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

  @type provider_name :: :amp | :claude | :codex | :codex_exec | :gemini | atom()

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

  @spec resolve(t() | provider_name()) :: {:ok, t()} | {:error, Error.t()}
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
        sdk_runtime: Module.concat(["ClaudeAgentSDK", "Runtime", "CLI"]),
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
        sdk_runtime: Module.concat(["Codex", "Runtime", "Exec"]),
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
      gemini: %__MODULE__{
        name: :gemini,
        display_name: "Gemini CLI",
        core_profile: CliSubprocessCore.ProviderProfiles.Gemini,
        sdk_runtime: Module.concat(["GeminiCliSdk", "Runtime", "CLI"]),
        example_support: %ExampleSupport{
          cli_command: "gemini",
          cli_path_env: "GEMINI_CLI_PATH",
          install_hint: "npm install -g @google/gemini-cli",
          model_env: "ASM_GEMINI_MODEL",
          example_default_model: "gemini-3.1-flash-lite-preview",
          sdk_app: :gemini_cli_sdk,
          sdk_repo_dir: "gemini_cli_sdk",
          sdk_root_env: "GEMINI_CLI_SDK_ROOT",
          sdk_cli_env: "GEMINI_CLI_PATH"
        },
        options_schema: ASM.Options.Gemini.schema(),
        feature_manifest: feature_manifest_for(:gemini),
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
        sdk_runtime: Module.concat(["AmpSdk", "Runtime", "CLI"]),
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
      }
    }
  end

  defp normalize_name(:codex_exec), do: :codex
  defp normalize_name(name), do: name

  defp feature_manifest_for(provider) when is_atom(provider) do
    ollama =
      provider
      |> CoreProviderFeatures.partial_feature!(:ollama)
      |> Map.merge(%{
        common_surface: true,
        common_opts: [:ollama, :ollama_model, :ollama_base_url, :ollama_http, :ollama_timeout_ms]
      })

    %{ollama: ollama}
  end
end
