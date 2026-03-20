defmodule ASM.Provider do
  @moduledoc """
  Provider definition data used by the backend registry.
  """

  alias ASM.Error
  alias ASM.Provider.Profile

  @enforce_keys [:name, :display_name, :core_profile, :options_schema, :profile]
  defstruct [
    :name,
    :display_name,
    :core_profile,
    :sdk_runtime,
    :options_schema,
    :profile,
    aliases: [],
    metadata: %{}
  ]

  @type provider_name :: :amp | :claude | :codex | :codex_exec | :gemini | atom()

  @type t :: %__MODULE__{
          name: provider_name(),
          display_name: String.t(),
          core_profile: module(),
          sdk_runtime: module() | nil,
          options_schema: keyword(),
          profile: Profile.t(),
          aliases: [provider_name()],
          metadata: map()
        }

  @providers %{
    claude: %__MODULE__{
      name: :claude,
      display_name: "Claude CLI",
      core_profile: CliSubprocessCore.ProviderProfiles.Claude,
      sdk_runtime: ClaudeAgentSDK.Runtime.CLI,
      options_schema: ASM.Options.Claude.schema(),
      profile:
        Profile.new!(
          transport_mode: :persistent_stdio,
          input_mode: :stdin,
          control_mode: :stdio_bidirectional,
          session_mode: :provider_managed,
          transport_restart: :transient,
          max_concurrent_runs: 1,
          max_queued_runs: 10
        )
    },
    codex: %__MODULE__{
      name: :codex,
      display_name: "Codex CLI",
      core_profile: CliSubprocessCore.ProviderProfiles.Codex,
      sdk_runtime: Codex.Runtime.Exec,
      options_schema: ASM.Options.Codex.schema(),
      aliases: [:codex_exec],
      profile:
        Profile.new!(
          transport_mode: :exec_stdio,
          input_mode: :flag,
          control_mode: :none,
          session_mode: :asm_managed,
          max_concurrent_runs: 1,
          max_queued_runs: 10
        )
    },
    gemini: %__MODULE__{
      name: :gemini,
      display_name: "Gemini CLI",
      core_profile: CliSubprocessCore.ProviderProfiles.Gemini,
      sdk_runtime: GeminiCliSdk.Runtime.CLI,
      options_schema: ASM.Options.Gemini.schema(),
      profile:
        Profile.new!(
          transport_mode: :exec_stdio,
          input_mode: :flag,
          control_mode: :none,
          session_mode: :asm_managed,
          max_concurrent_runs: 1,
          max_queued_runs: 10
        )
    },
    amp: %__MODULE__{
      name: :amp,
      display_name: "Amp CLI",
      core_profile: CliSubprocessCore.ProviderProfiles.Amp,
      sdk_runtime: AmpSdk.Runtime.CLI,
      options_schema: ASM.Options.Amp.schema(),
      profile:
        Profile.new!(
          transport_mode: :exec_stdio,
          input_mode: :flag,
          control_mode: :none,
          session_mode: :asm_managed,
          max_concurrent_runs: 1,
          max_queued_runs: 10
        )
    }
  }

  @spec supported_providers() :: [provider_name()]
  def supported_providers, do: Map.keys(@providers)

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
    case Map.fetch(@providers, normalize_name(name)) do
      {:ok, provider} -> {:ok, provider}
      :error -> find_alias(name)
    end
  end

  defp find_alias(name) do
    Enum.find_value(@providers, :error, fn {_id, provider} ->
      if name in provider.aliases do
        {:ok, provider}
      else
        false
      end
    end)
  end

  defp normalize_name(:codex_exec), do: :codex
  defp normalize_name(name), do: name
end
