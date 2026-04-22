defmodule ASM.AdapterSelectionPolicy do
  @moduledoc """
  Phase 6 adapter selection policy declaration for ASM provider resolution.

  ASM consumes CLI core runtime profile configuration as a provider-registry
  rule. It does not expose request-time simulation selectors.
  """

  @contract_version "ExecutionPlane.AdapterSelectionPolicy.v1"
  @owner_repo "agent_session_manager"
  @selection_surfaces [
    "application_config",
    "adapter_registry",
    "transport_registry",
    "provider_registry",
    "backend_manifest",
    "profile_registry_install"
  ]

  defstruct [
    :contract_version,
    :selection_surface,
    :owner_repo,
    :config_key,
    :default_value_when_unset,
    :fail_closed_action_when_misconfigured
  ]

  @type t :: %__MODULE__{
          contract_version: String.t(),
          selection_surface: String.t(),
          owner_repo: String.t(),
          config_key: String.t(),
          default_value_when_unset: String.t(),
          fail_closed_action_when_misconfigured: String.t()
        }

  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @spec owner_repo() :: String.t()
  def owner_repo, do: @owner_repo

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = value), do: {:ok, value}

  def new(attrs) do
    {:ok, build(attrs)}
  rescue
    error in ArgumentError -> {:error, error}
  end

  @spec new!(map() | keyword() | t()) :: t()
  def new!(%__MODULE__{} = value), do: value

  def new!(attrs) do
    case new(attrs) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = policy) do
    policy
    |> Map.from_struct()
    |> stringify_contract()
  end

  defp build(attrs) do
    attrs = normalize_attrs(attrs)
    reject_public_simulation_selector!(attrs)

    config_key = fetch_required_stringish!(attrs, :config_key)
    reject_public_simulation_config_key!(config_key)

    %__MODULE__{
      contract_version: validate_contract_version!(attrs),
      selection_surface:
        attrs
        |> fetch_required_stringish!(:selection_surface)
        |> validate_selection_surface!(),
      owner_repo: validate_owner_repo!(fetch_required_stringish!(attrs, :owner_repo)),
      config_key: config_key,
      default_value_when_unset: fetch_required_stringish!(attrs, :default_value_when_unset),
      fail_closed_action_when_misconfigured:
        fetch_required_stringish!(attrs, :fail_closed_action_when_misconfigured)
    }
  end

  defp normalize_attrs(attrs) when is_map(attrs), do: attrs

  defp normalize_attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      Map.new(attrs)
    else
      raise ArgumentError, "expected keyword attrs, got: #{inspect(attrs)}"
    end
  end

  defp normalize_attrs(attrs) do
    raise ArgumentError, "expected map or keyword attrs, got: #{inspect(attrs)}"
  end

  defp fetch_required_stringish!(attrs, key) do
    attrs
    |> fetch_value(key)
    |> validate_non_empty_string!(to_string(key))
  end

  defp fetch_value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp validate_non_empty_string!(value, _field_name)
       when is_binary(value) and byte_size(value) > 0,
       do: value

  defp validate_non_empty_string!(value, field_name) when is_atom(value) do
    value
    |> Atom.to_string()
    |> validate_non_empty_string!(field_name)
  end

  defp validate_non_empty_string!(value, field_name) do
    raise ArgumentError, "#{field_name} must be a non-empty string, got: #{inspect(value)}"
  end

  defp validate_contract_version!(attrs) do
    version = fetch_value(attrs, :contract_version) || @contract_version

    if version == @contract_version do
      version
    else
      raise ArgumentError,
            "expected contract_version #{inspect(@contract_version)}, got: #{inspect(version)}"
    end
  end

  defp reject_public_simulation_selector!(attrs) do
    if Map.has_key?(attrs, :simulation) or Map.has_key?(attrs, "simulation") do
      raise ArgumentError,
            "public simulation selector is forbidden; use owner registry configuration"
    end
  end

  defp reject_public_simulation_config_key!(config_key) do
    if config_key == "simulation" or String.contains?(config_key, ".simulation") do
      raise ArgumentError, "config_key must not be a public simulation selector"
    end
  end

  defp validate_selection_surface!(selection_surface) do
    if selection_surface in @selection_surfaces do
      selection_surface
    else
      raise ArgumentError, "selection_surface unsupported value: #{inspect(selection_surface)}"
    end
  end

  defp validate_owner_repo!(@owner_repo), do: @owner_repo

  defp validate_owner_repo!(owner_repo) do
    raise ArgumentError, "owner_repo must be #{@owner_repo}, got: #{inspect(owner_repo)}"
  end

  defp stringify_contract(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), value} end)
  end
end
