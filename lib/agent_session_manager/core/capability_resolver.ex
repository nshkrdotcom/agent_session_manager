defmodule AgentSessionManager.Core.CapabilityResolver do
  @moduledoc """
  Negotiates capabilities between required/optional sets and available provider capabilities.

  The CapabilityResolver accepts a set of required and optional capability types,
  then negotiates against a list of provider capabilities to determine which
  capabilities are supported, unsupported, and whether the negotiation succeeds.

  ## Negotiation Behavior

  - **Required capabilities**: If any required capability type is missing from the
    provider, negotiation fails immediately with an error.
  - **Optional capabilities**: Missing optional capabilities result in a `degraded`
    status with warnings, but negotiation still succeeds.
  - **Full support**: When all required and optional capabilities are satisfied,
    the result status is `full`.

  ## Usage

      # Create a resolver with required and optional capabilities
      {:ok, resolver} = CapabilityResolver.new(
        required: [:tool, :resource],
        optional: [:sampling]
      )

      # Negotiate against provider capabilities
      provider_capabilities = [
        %Capability{name: "web_search", type: :tool, enabled: true},
        %Capability{name: "file_access", type: :resource, enabled: true}
      ]

      case CapabilityResolver.negotiate(resolver, provider_capabilities) do
        {:ok, result} ->
          IO.puts("Status: \#{result.status}")
          IO.puts("Supported: \#{inspect(result.supported)}")
          IO.puts("Warnings: \#{inspect(result.warnings)}")

        {:error, error} ->
          IO.puts("Negotiation failed: \#{error.message}")
      end

  ## Helper Functions

  The module also provides utilities for working with capability lists:

      # Check if a capability type is present
      CapabilityResolver.has_capability_type?(capabilities, :tool)

      # Get all capabilities of a specific type
      tools = CapabilityResolver.capabilities_of_type(capabilities, :tool)

  """

  alias AgentSessionManager.Core.{Capability, Error}

  @type t :: %__MODULE__{
          required: MapSet.t(atom()),
          optional: MapSet.t(atom())
        }

  defstruct required: MapSet.new(),
            optional: MapSet.new()

  defmodule NegotiationResult do
    @moduledoc """
    Represents the result of a capability negotiation.

    ## Fields

    - `status` - `:full` when all capabilities satisfied, `:degraded` when optional missing
    - `supported` - MapSet of capability types that are supported
    - `unsupported` - MapSet of capability types that are not supported (optional only)
    - `warnings` - List of warning messages for missing optional capabilities
    """

    @type status :: :full | :degraded | :unknown

    @type t :: %__MODULE__{
            status: status(),
            supported: MapSet.t(atom()),
            unsupported: MapSet.t(atom()),
            warnings: [String.t()]
          }

    defstruct status: :unknown,
              supported: MapSet.new(),
              unsupported: MapSet.new(),
              warnings: []
  end

  @doc """
  Creates a new CapabilityResolver with the given required and optional capability types.

  ## Options

  - `:required` - List of required capability types (atoms or strings)
  - `:optional` - List of optional capability types (atoms or strings)

  ## Examples

      iex> CapabilityResolver.new(required: [:tool], optional: [:sampling])
      {:ok, %CapabilityResolver{required: MapSet.new([:tool]), optional: MapSet.new([:sampling])}}

      iex> CapabilityResolver.new(required: [:invalid_type])
      {:error, %Error{code: :invalid_capability_type}}

  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) do
    required = Keyword.get(opts, :required, [])
    optional = Keyword.get(opts, :optional, [])

    with {:ok, required_set} <- validate_capability_types(required, "required"),
         {:ok, optional_set} <- validate_capability_types(optional, "optional") do
      {:ok,
       %__MODULE__{
         required: required_set,
         optional: optional_set
       }}
    end
  end

  @doc """
  Negotiates capabilities between the resolver's requirements and provider capabilities.

  Returns `{:ok, result}` if all required capabilities are satisfied, or
  `{:error, error}` if any required capability is missing.

  ## Examples

      iex> {:ok, resolver} = CapabilityResolver.new(required: [:tool])
      iex> capabilities = [%Capability{name: "search", type: :tool, enabled: true}]
      iex> {:ok, result} = CapabilityResolver.negotiate(resolver, capabilities)
      iex> result.status
      :full

  """
  @spec negotiate(t(), [Capability.t()]) :: {:ok, NegotiationResult.t()} | {:error, Error.t()}
  def negotiate(%__MODULE__{} = resolver, capabilities) when is_list(capabilities) do
    # Get set of enabled capability types from provider
    enabled_types = extract_enabled_types(capabilities)

    # Check required capabilities first (fail fast)
    missing_required = MapSet.difference(resolver.required, enabled_types)

    if MapSet.size(missing_required) > 0 do
      missing_list = MapSet.to_list(missing_required)
      missing_str = Enum.map_join(missing_list, ", ", &Atom.to_string/1)

      {:error,
       Error.new(
         :missing_required_capability,
         "Missing required capability types: #{missing_str}"
       )}
    else
      # All required capabilities are present, check optional
      negotiate_optional(resolver, enabled_types)
    end
  end

  @doc """
  Returns all capabilities from the list that have the specified type.

  Only considers enabled capabilities.

  ## Examples

      iex> capabilities = [%Capability{name: "search", type: :tool, enabled: true}]
      iex> CapabilityResolver.capabilities_of_type(capabilities, :tool)
      [%Capability{name: "search", type: :tool, enabled: true}]

  """
  @spec capabilities_of_type([Capability.t()], atom()) :: [Capability.t()]
  def capabilities_of_type(capabilities, type) when is_list(capabilities) and is_atom(type) do
    Enum.filter(capabilities, fn cap ->
      cap.type == type && cap.enabled
    end)
  end

  @doc """
  Checks if the capability list contains at least one enabled capability of the given type.

  ## Examples

      iex> capabilities = [%Capability{name: "search", type: :tool, enabled: true}]
      iex> CapabilityResolver.has_capability_type?(capabilities, :tool)
      true

      iex> CapabilityResolver.has_capability_type?(capabilities, :sampling)
      false

  """
  @spec has_capability_type?([Capability.t()], atom()) :: boolean()
  def has_capability_type?(capabilities, type) when is_list(capabilities) and is_atom(type) do
    Enum.any?(capabilities, fn cap ->
      cap.type == type && cap.enabled
    end)
  end

  # Private helpers

  defp validate_capability_types(types, _context) when is_list(types) do
    normalized =
      Enum.map(types, fn
        type when is_atom(type) -> type
        type when is_binary(type) -> String.to_existing_atom(type)
      end)

    invalid = Enum.reject(normalized, &Capability.valid_type?/1)

    case invalid do
      [] ->
        {:ok, MapSet.new(normalized)}

      [first | _] ->
        {:error,
         Error.new(
           :invalid_capability_type,
           "Invalid capability type: #{inspect(first)}"
         )}
    end
  rescue
    ArgumentError ->
      {:error, Error.new(:invalid_capability_type, "Invalid capability type specified")}
  end

  defp extract_enabled_types(capabilities) do
    capabilities
    |> Enum.filter(& &1.enabled)
    |> Enum.map(& &1.type)
    |> MapSet.new()
  end

  defp negotiate_optional(resolver, enabled_types) do
    # Calculate supported capabilities (required + optional that are present)
    all_requested = MapSet.union(resolver.required, resolver.optional)
    supported = MapSet.intersection(all_requested, enabled_types)

    # Calculate unsupported optional capabilities
    missing_optional = MapSet.difference(resolver.optional, enabled_types)

    # Generate warnings for missing optional capabilities
    warnings =
      missing_optional
      |> MapSet.to_list()
      |> Enum.map(&"Optional capability '#{&1}' is not supported by the provider")

    # Determine status
    status =
      if MapSet.size(missing_optional) > 0 do
        :degraded
      else
        :full
      end

    {:ok,
     %NegotiationResult{
       status: status,
       supported: supported,
       unsupported: missing_optional,
       warnings: warnings
     }}
  end
end
