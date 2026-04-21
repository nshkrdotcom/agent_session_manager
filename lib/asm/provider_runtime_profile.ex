defmodule ASM.ProviderRuntimeProfile do
  @moduledoc """
  ASM view of configured CLI core provider runtime profiles.

  The executable profile remains owned by `cli_subprocess_core` application
  configuration. ASM consumes the same configured profile boundary to keep lane
  selection on the core backend and to fail closed before SDK or backend
  overrides can bypass the common CLI runtime path.
  """

  alias ASM.Error

  @config_app :cli_subprocess_core
  @config_key :provider_runtime_profiles
  @lower_simulation :lower_simulation
  @missing {__MODULE__, :missing}

  @type t :: %{
          required(:mode) => :lower_simulation,
          required(:ref) => String.t(),
          required(:source) => :cli_subprocess_core_config
        }

  @spec resolve(atom()) :: {:ok, t() | nil} | {:error, Error.t()}
  def resolve(provider) when is_atom(provider) do
    config = Application.get_env(@config_app, @config_key)

    with {:ok, required?} <- required?(config, provider),
         {:ok, profile} <- configured_profile(config, provider) do
      case profile do
        nil when required? ->
          {:error,
           config_error(
             "provider runtime profile required for #{inspect(provider)} but no profile is configured",
             provider,
             %{provider: provider}
           )}

        nil ->
          {:ok, nil}

        profile ->
          normalize_profile(provider, profile)
      end
    end
  end

  def resolve(provider) do
    {:error,
     config_error(
       "provider runtime profile provider must be an atom, got: #{inspect(provider)}",
       nil,
       %{provider: provider}
     )}
  end

  @spec observability(t() | nil) :: map()
  def observability(nil), do: %{}

  def observability(%{mode: mode, ref: ref, source: source}) do
    %{
      provider_runtime_profile?: true,
      provider_runtime_profile_mode: mode,
      provider_runtime_profile_ref: ref,
      provider_runtime_profile_source: source
    }
  end

  defp normalize_profile(provider, profile) do
    with {:ok, @lower_simulation} <- mode(provider, profile),
         {:ok, scenario_ref} <- required_profile_string(provider, profile, :scenario_ref) do
      {:ok,
       %{
         mode: @lower_simulation,
         ref: scenario_ref,
         source: :cli_subprocess_core_config
       }}
    else
      {:error, {:unsupported_mode, mode}} ->
        {:error,
         config_error(
           "unsupported provider runtime profile mode #{inspect(mode)} for #{inspect(provider)}",
           provider,
           %{provider: provider, mode: mode}
         )}

      {:error, reason} ->
        {:error,
         config_error(
           "invalid provider runtime profile for #{inspect(provider)}: #{inspect(reason)}",
           provider,
           %{provider: provider, reason: reason}
         )}
    end
  end

  defp required?(config, provider) do
    case config_value(config, :required?, false) do
      value when is_boolean(value) ->
        {:ok, value}

      other ->
        {:error,
         config_error(
           "invalid provider runtime profile required? flag #{inspect(other)}",
           provider,
           %{provider: provider, required?: other}
         )}
    end
  end

  defp configured_profile(nil, _provider), do: {:ok, nil}

  defp configured_profile(config, provider) when is_list(config) or is_map(config) do
    profile =
      config
      |> config_value(:profiles, %{})
      |> provider_profile(provider)

    case profile do
      nil ->
        {:ok, nil}

      false ->
        {:ok, nil}

      profile when is_list(profile) or is_map(profile) ->
        if config_value(profile, :enabled?, true) == false do
          {:ok, nil}
        else
          {:ok, profile}
        end

      other ->
        {:error,
         config_error(
           "invalid provider runtime profile for #{inspect(provider)}: #{inspect(other)}",
           provider,
           %{provider: provider, profile: other}
         )}
    end
  end

  defp configured_profile(config, provider) do
    {:error,
     config_error(
       "invalid provider runtime profile config #{inspect(config)}",
       provider,
       %{provider: provider, config: config}
     )}
  end

  defp mode(provider, profile) do
    profile
    |> profile_value(
      :mode,
      profile_value(profile, :adapter, profile_value(profile, :surface_kind, @lower_simulation))
    )
    |> normalize_mode(provider)
  end

  defp normalize_mode(@lower_simulation, _provider), do: {:ok, @lower_simulation}
  defp normalize_mode("lower_simulation", _provider), do: {:ok, @lower_simulation}
  defp normalize_mode(other, _provider), do: {:error, {:unsupported_mode, other}}

  defp required_profile_string(provider, profile, key) do
    case profile_value(profile, key, nil) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, {:missing_required_option, key, other || provider}}
    end
  end

  defp provider_profile(profiles, provider) when is_list(profiles) or is_map(profiles) do
    config_value(profiles, provider, nil)
  end

  defp provider_profile(_profiles, _provider), do: nil

  defp profile_value(profile, key, default) do
    case config_value(profile, key, @missing) do
      @missing ->
        transport_options = config_value(profile, :transport_options, %{})

        case config_value(transport_options, key, @missing) do
          @missing -> default
          nil -> default
          value -> value
        end

      nil ->
        default

      value ->
        value
    end
  end

  defp config_value(nil, _key, default), do: default

  defp config_value(config, key, default) when is_list(config) do
    case Enum.find(config, &matching_key?(&1, key)) do
      {_key, value} -> value
      nil -> default
    end
  end

  defp config_value(config, key, default) when is_map(config) do
    Map.get(config, key, Map.get(config, to_string(key), default))
  end

  defp config_value(_config, _key, default), do: default

  defp matching_key?({key, _value}, key), do: true

  defp matching_key?({entry_key, _value}, key) when is_binary(entry_key) and is_atom(key) do
    entry_key == Atom.to_string(key)
  end

  defp matching_key?(_entry, _key), do: false

  defp config_error(message, provider, cause) do
    Error.new(:config_invalid, :config, message, provider: provider, cause: cause)
  end
end
