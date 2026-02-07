defmodule AgentSessionManager.Core.Manifest do
  @moduledoc """
  Represents an agent manifest that defines the agent's configuration and capabilities.

  The manifest is a declarative description of an agent, including
  its name, version, provider, and the capabilities it supports.

  ## Fields

  - `name` - The agent name
  - `version` - The manifest version (semver)
  - `description` - Optional description
  - `provider` - The AI provider (e.g., "anthropic", "openai")
  - `capabilities` - List of Capability structs
  - `config` - Agent-specific configuration
  - `metadata` - Arbitrary metadata

  ## Usage

      # Create a manifest
      {:ok, manifest} = Manifest.new(%{
        name: "my-agent",
        version: "1.0.0",
        provider: "anthropic",
        capabilities: [
          %{name: "web_search", type: :tool}
        ]
      })

      # Add a capability
      {:ok, updated} = Manifest.add_capability(manifest, %{
        name: "file_read",
        type: :file_access
      })

      # Get enabled capabilities
      enabled = Manifest.enabled_capabilities(manifest)

  """

  alias AgentSessionManager.Core.{Capability, Error, Serialization}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          version: String.t() | nil,
          description: String.t() | nil,
          provider: String.t() | nil,
          capabilities: [Capability.t()],
          config: map(),
          metadata: map()
        }

  defstruct [
    :name,
    :version,
    :description,
    :provider,
    capabilities: [],
    config: %{},
    metadata: %{}
  ]

  @doc """
  Creates a new manifest with the given attributes.

  ## Required

  - `:name` - The agent name
  - `:version` - The manifest version

  ## Optional

  - `:description` - Description of the agent
  - `:provider` - The AI provider
  - `:capabilities` - List of capabilities (as Capability structs or maps)
  - `:config` - Agent configuration
  - `:metadata` - Arbitrary metadata

  ## Examples

      iex> Manifest.new(%{name: "my-agent", version: "1.0.0"})
      {:ok, %Manifest{name: "my-agent", version: "1.0.0"}}

      iex> Manifest.new(%{name: ""})
      {:error, %Error{code: :validation_error}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- validate_name(attrs),
         {:ok, version} <- validate_version(attrs),
         {:ok, capabilities} <- validate_capabilities(attrs) do
      manifest = %__MODULE__{
        name: name,
        version: version,
        description: Map.get(attrs, :description),
        provider: Map.get(attrs, :provider),
        capabilities: capabilities,
        config: Map.get(attrs, :config, %{}),
        metadata: Map.get(attrs, :metadata, %{})
      }

      {:ok, manifest}
    end
  end

  @doc """
  Adds a capability to the manifest.

  Returns an error if a capability with the same name already exists.
  """
  @spec add_capability(t(), Capability.t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def add_capability(%__MODULE__{} = manifest, %Capability{} = capability) do
    if capability_exists?(manifest, capability.name) do
      {:error, Error.new(:duplicate_capability, "Capability '#{capability.name}' already exists")}
    else
      updated = %{manifest | capabilities: manifest.capabilities ++ [capability]}
      {:ok, updated}
    end
  end

  def add_capability(%__MODULE__{} = manifest, attrs) when is_map(attrs) do
    case Capability.new(attrs) do
      {:ok, capability} -> add_capability(manifest, capability)
      {:error, _} = error -> error
    end
  end

  @doc """
  Removes a capability by name.

  Returns an error if the capability is not found.
  """
  @spec remove_capability(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def remove_capability(%__MODULE__{} = manifest, name) when is_binary(name) do
    if capability_exists?(manifest, name) do
      updated_capabilities = Enum.reject(manifest.capabilities, &(&1.name == name))
      {:ok, %{manifest | capabilities: updated_capabilities}}
    else
      {:error, Error.new(:capability_not_found, "Capability '#{name}' not found")}
    end
  end

  @doc """
  Gets a capability by name.

  Returns an error if the capability is not found.
  """
  @spec get_capability(t(), String.t()) :: {:ok, Capability.t()} | {:error, Error.t()}
  def get_capability(%__MODULE__{} = manifest, name) when is_binary(name) do
    case Enum.find(manifest.capabilities, &(&1.name == name)) do
      nil -> {:error, Error.new(:capability_not_found, "Capability '#{name}' not found")}
      capability -> {:ok, capability}
    end
  end

  @doc """
  Returns only enabled capabilities.
  """
  @spec enabled_capabilities(t()) :: [Capability.t()]
  def enabled_capabilities(%__MODULE__{} = manifest) do
    Enum.filter(manifest.capabilities, & &1.enabled)
  end

  @doc """
  Converts a manifest to a map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = manifest) do
    %{
      "name" => manifest.name,
      "version" => manifest.version,
      "description" => manifest.description,
      "provider" => manifest.provider,
      "capabilities" => Enum.map(manifest.capabilities, &Capability.to_map/1),
      "config" => Serialization.stringify_keys(manifest.config),
      "metadata" => Serialization.stringify_keys(manifest.metadata)
    }
  end

  @doc """
  Reconstructs a manifest from a map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) when is_map(map) do
    with {:ok, name} <- get_required_string(map, "name"),
         {:ok, version} <- get_required_string(map, "version"),
         {:ok, capabilities} <- parse_capabilities(map["capabilities"]) do
      manifest = %__MODULE__{
        name: name,
        version: version,
        description: map["description"],
        provider: map["provider"],
        capabilities: capabilities,
        config: Serialization.atomize_keys(map["config"] || %{}),
        metadata: Serialization.atomize_keys(map["metadata"] || %{})
      }

      {:ok, manifest}
    end
  end

  def from_map(_), do: {:error, Error.new(:validation_error, "Invalid manifest map")}

  # Private helpers

  defp validate_name(%{name: name}) when is_binary(name) and name != "" do
    {:ok, name}
  end

  defp validate_name(%{name: ""}),
    do: {:error, Error.new(:validation_error, "name cannot be empty")}

  defp validate_name(_),
    do: {:error, Error.new(:validation_error, "name is required")}

  defp validate_version(%{version: version}) when is_binary(version) and version != "" do
    {:ok, version}
  end

  defp validate_version(%{version: ""}),
    do: {:error, Error.new(:validation_error, "version cannot be empty")}

  defp validate_version(_),
    do: {:error, Error.new(:validation_error, "version is required")}

  defp validate_capabilities(%{capabilities: capabilities}) when is_list(capabilities) do
    results =
      Enum.map(capabilities, fn
        %Capability{} = cap -> {:ok, cap}
        attrs when is_map(attrs) -> Capability.new(attrs)
        _ -> {:error, Error.new(:validation_error, "Invalid capability")}
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    case errors do
      [] -> {:ok, Enum.map(results, fn {:ok, cap} -> cap end)}
      [{:error, error} | _] -> {:error, error}
    end
  end

  defp validate_capabilities(_), do: {:ok, []}

  defp capability_exists?(%__MODULE__{} = manifest, name) do
    Enum.any?(manifest.capabilities, &(&1.name == name))
  end

  defp get_required_string(map, key) do
    case Map.get(map, key) do
      nil -> {:error, Error.new(:validation_error, "#{key} is required")}
      "" -> {:error, Error.new(:validation_error, "#{key} cannot be empty")}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, Error.new(:validation_error, "#{key} must be a string")}
    end
  end

  defp parse_capabilities(nil), do: {:ok, []}
  defp parse_capabilities([]), do: {:ok, []}

  defp parse_capabilities(capabilities) when is_list(capabilities) do
    results = Enum.map(capabilities, &Capability.from_map/1)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    case errors do
      [] -> {:ok, Enum.map(results, fn {:ok, cap} -> cap end)}
      [{:error, error} | _] -> {:error, error}
    end
  end
end
