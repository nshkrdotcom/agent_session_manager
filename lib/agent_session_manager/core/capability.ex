defmodule AgentSessionManager.Core.Capability do
  @moduledoc """
  Represents a capability that can be assigned to an agent.

  Capabilities define what an agent can do, including tools,
  resources, prompts, and various access permissions.

  ## Capability Types

  - `:tool` - A tool the agent can invoke
  - `:resource` - A resource the agent can access
  - `:prompt` - A prompt template
  - `:sampling` - Sampling/generation capability
  - `:file_access` - File system access
  - `:network_access` - Network/HTTP access
  - `:code_execution` - Code execution capability

  ## Fields

  - `name` - Unique capability name
  - `type` - The capability type
  - `enabled` - Whether the capability is currently enabled
  - `description` - Optional description
  - `config` - Capability-specific configuration
  - `permissions` - List of permissions required/granted

  ## Usage

      # Create a capability
      {:ok, cap} = Capability.new(%{
        name: "web_search",
        type: :tool,
        description: "Search the web for information"
      })

      # Disable a capability
      disabled = Capability.disable(cap)

  """

  alias AgentSessionManager.Core.{Error, Serialization}

  @valid_types [
    :tool,
    :resource,
    :prompt,
    :sampling,
    :file_access,
    :network_access,
    :code_execution
  ]

  @type capability_type ::
          :tool
          | :resource
          | :prompt
          | :sampling
          | :file_access
          | :network_access
          | :code_execution

  @type t :: %__MODULE__{
          name: String.t() | nil,
          type: capability_type() | nil,
          enabled: boolean(),
          description: String.t() | nil,
          config: map(),
          permissions: [String.t()]
        }

  defstruct [
    :name,
    :type,
    :description,
    enabled: true,
    config: %{},
    permissions: []
  ]

  @doc """
  Checks if the given type is a valid capability type.
  """
  @spec valid_type?(atom()) :: boolean()
  def valid_type?(type) when is_atom(type), do: type in @valid_types
  def valid_type?(_), do: false

  @doc """
  Returns all valid capability types.
  """
  @spec all_types() :: [capability_type()]
  def all_types, do: @valid_types

  @doc """
  Creates a new capability with the given attributes.

  ## Required

  - `:name` - The capability name
  - `:type` - The capability type

  ## Optional

  - `:enabled` - Whether enabled (default: true)
  - `:description` - Description of the capability
  - `:config` - Configuration map
  - `:permissions` - List of permission strings

  ## Examples

      iex> Capability.new(%{name: "web_search", type: :tool})
      {:ok, %Capability{name: "web_search", type: :tool, enabled: true}}

      iex> Capability.new(%{name: "", type: :tool})
      {:error, %Error{code: :validation_error}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- validate_name(attrs),
         {:ok, type} <- validate_type(attrs) do
      capability = %__MODULE__{
        name: name,
        type: type,
        enabled: Map.get(attrs, :enabled, true),
        description: Map.get(attrs, :description),
        config: Map.get(attrs, :config, %{}),
        permissions: Map.get(attrs, :permissions, [])
      }

      {:ok, capability}
    end
  end

  @doc """
  Enables a capability.
  """
  @spec enable(t()) :: t()
  def enable(%__MODULE__{} = capability) do
    %{capability | enabled: true}
  end

  @doc """
  Disables a capability.
  """
  @spec disable(t()) :: t()
  def disable(%__MODULE__{} = capability) do
    %{capability | enabled: false}
  end

  @doc """
  Converts a capability to a map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = capability) do
    %{
      "name" => capability.name,
      "type" => Atom.to_string(capability.type),
      "enabled" => capability.enabled,
      "description" => capability.description,
      "config" => Serialization.stringify_keys(capability.config),
      "permissions" => capability.permissions
    }
  end

  @doc """
  Reconstructs a capability from a map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) when is_map(map) do
    with {:ok, name} <- get_required_string(map, "name"),
         {:ok, type} <- parse_type(map["type"]) do
      capability = %__MODULE__{
        name: name,
        type: type,
        enabled: Map.get(map, "enabled", true),
        description: map["description"],
        config: Serialization.atomize_keys(map["config"] || %{}),
        permissions: map["permissions"] || []
      }

      {:ok, capability}
    end
  end

  def from_map(_), do: {:error, Error.new(:validation_error, "Invalid capability map")}

  # Private helpers

  defp validate_name(%{name: name}) when is_binary(name) and name != "" do
    {:ok, name}
  end

  defp validate_name(%{name: ""}),
    do: {:error, Error.new(:validation_error, "name cannot be empty")}

  defp validate_name(_),
    do: {:error, Error.new(:validation_error, "name is required")}

  defp validate_type(%{type: type}) when is_atom(type) do
    if valid_type?(type) do
      {:ok, type}
    else
      {:error, Error.new(:invalid_capability_type, "Invalid capability type: #{inspect(type)}")}
    end
  end

  defp validate_type(_), do: {:error, Error.new(:validation_error, "type is required")}

  defp get_required_string(map, key) do
    case Map.get(map, key) do
      nil -> {:error, Error.new(:validation_error, "#{key} is required")}
      "" -> {:error, Error.new(:validation_error, "#{key} cannot be empty")}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, Error.new(:validation_error, "#{key} must be a string")}
    end
  end

  defp parse_type(nil), do: {:error, Error.new(:validation_error, "type is required")}

  defp parse_type(type) when is_binary(type) do
    atom = String.to_existing_atom(type)

    if valid_type?(atom) do
      {:ok, atom}
    else
      {:error, Error.new(:invalid_capability_type, "Invalid capability type: #{type}")}
    end
  rescue
    ArgumentError ->
      {:error, Error.new(:invalid_capability_type, "Invalid capability type: #{type}")}
  end

  defp parse_type(_), do: {:error, Error.new(:validation_error, "type must be a string")}
end
