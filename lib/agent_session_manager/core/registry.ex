defmodule AgentSessionManager.Core.Registry do
  @moduledoc """
  A thread-safe registry for storing and retrieving provider manifests.

  The Registry provides deterministic operations for managing provider manifests,
  including registration, retrieval, update, and filtering capabilities.

  ## Thread Safety

  The Registry uses immutable data structures, making all operations inherently
  thread-safe. Each operation returns a new Registry struct without mutating
  the original, enabling safe concurrent access patterns.

  ## Determinism

  All operations are deterministic - the same inputs will always produce the
  same outputs. The `list/1` function returns manifests in a consistent order
  (sorted alphabetically by name).

  ## Usage

      # Create a registry
      registry = Registry.new()

      # Register a manifest
      {:ok, manifest} = Manifest.new(%{name: "my-agent", version: "1.0.0"})
      {:ok, registry} = Registry.register(registry, manifest)

      # Retrieve a manifest
      {:ok, retrieved} = Registry.get(registry, "my-agent")

      # List all manifests
      manifests = Registry.list(registry)

      # Filter by provider
      anthropic_agents = Registry.filter_by_provider(registry, "anthropic")

      # Filter by capability
      tool_agents = Registry.filter_by_capability(registry, :tool)

  ## Validation

  The Registry validates manifests before registration, providing helpful
  error messages for common issues:

      result = Registry.validate_manifest(manifest)
      case result do
        :ok -> IO.puts("Valid!")
        {:error, error} -> IO.puts("Error: \#{error.message}")
      end

  """

  alias AgentSessionManager.Core.{Manifest, Capability, Error}

  @type t :: %__MODULE__{
          manifests: %{String.t() => Manifest.t()},
          metadata: map()
        }

  defstruct manifests: %{},
            metadata: %{}

  @doc """
  Creates a new empty registry.

  ## Examples

      iex> Registry.new()
      %Registry{manifests: %{}, metadata: %{}}

  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new registry with the given options.

  ## Options

  - `:metadata` - Optional metadata map for the registry

  ## Examples

      iex> Registry.new(metadata: %{version: "1.0"})
      %Registry{manifests: %{}, metadata: %{version: "1.0"}}

  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      manifests: %{},
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Registers a new manifest in the registry.

  Returns an error if:
  - A manifest with the same name already exists
  - The manifest fails validation

  ## Examples

      iex> registry = Registry.new()
      iex> {:ok, manifest} = Manifest.new(%{name: "agent", version: "1.0.0"})
      iex> {:ok, updated} = Registry.register(registry, manifest)
      iex> Registry.exists?(updated, "agent")
      true

  """
  @spec register(t(), Manifest.t()) :: {:ok, t()} | {:error, Error.t()}
  def register(%__MODULE__{} = registry, %Manifest{} = manifest) do
    with :ok <- validate_manifest(manifest),
         :ok <- check_not_exists(registry, manifest.name) do
      updated = %{registry | manifests: Map.put(registry.manifests, manifest.name, manifest)}
      {:ok, updated}
    end
  end

  @doc """
  Removes a manifest from the registry by name.

  Returns an error if the manifest does not exist.

  ## Examples

      iex> {:ok, registry} = Registry.register(Registry.new(), manifest)
      iex> {:ok, updated} = Registry.unregister(registry, "my-agent")
      iex> Registry.exists?(updated, "my-agent")
      false

  """
  @spec unregister(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def unregister(%__MODULE__{} = registry, name) when is_binary(name) do
    if Map.has_key?(registry.manifests, name) do
      updated = %{registry | manifests: Map.delete(registry.manifests, name)}
      {:ok, updated}
    else
      {:error, Error.new(:not_found, "Manifest '#{name}' not found in registry")}
    end
  end

  @doc """
  Retrieves a manifest by name.

  Returns an error if the manifest does not exist.

  ## Examples

      iex> {:ok, retrieved} = Registry.get(registry, "my-agent")
      iex> retrieved.name
      "my-agent"

  """
  @spec get(t(), String.t()) :: {:ok, Manifest.t()} | {:error, Error.t()}
  def get(%__MODULE__{} = registry, name) when is_binary(name) do
    case Map.fetch(registry.manifests, name) do
      {:ok, manifest} -> {:ok, manifest}
      :error -> {:error, Error.new(:not_found, "Manifest '#{name}' not found in registry")}
    end
  end

  @doc """
  Lists all registered manifests in deterministic order (sorted by name).

  ## Examples

      iex> manifests = Registry.list(registry)
      iex> length(manifests)
      2

  """
  @spec list(t()) :: [Manifest.t()]
  def list(%__MODULE__{} = registry) do
    registry.manifests
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Checks if a manifest with the given name exists in the registry.

  ## Examples

      iex> Registry.exists?(registry, "my-agent")
      true

  """
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{} = registry, name) when is_binary(name) do
    Map.has_key?(registry.manifests, name)
  end

  @doc """
  Returns the count of registered manifests.

  ## Examples

      iex> Registry.count(registry)
      3

  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{} = registry) do
    map_size(registry.manifests)
  end

  @doc """
  Updates an existing manifest in the registry.

  The manifest must already exist (matched by name).
  Returns an error if the manifest does not exist.

  ## Examples

      iex> {:ok, updated_registry} = Registry.update(registry, updated_manifest)

  """
  @spec update(t(), Manifest.t()) :: {:ok, t()} | {:error, Error.t()}
  def update(%__MODULE__{} = registry, %Manifest{} = manifest) do
    if Map.has_key?(registry.manifests, manifest.name) do
      with :ok <- validate_manifest(manifest) do
        updated = %{registry | manifests: Map.put(registry.manifests, manifest.name, manifest)}
        {:ok, updated}
      end
    else
      {:error, Error.new(:not_found, "Manifest '#{manifest.name}' not found in registry")}
    end
  end

  @doc """
  Validates a manifest, returning `:ok` if valid or `{:error, error}` with
  a helpful error message if invalid.

  ## Validation Rules

  - Name must be present and non-empty
  - Version must be present and non-empty
  - All capabilities must be valid

  ## Examples

      iex> Registry.validate_manifest(valid_manifest)
      :ok

      iex> Registry.validate_manifest(%Manifest{})
      {:error, %Error{code: :validation_error, message: "Manifest name is required..."}}

  """
  @spec validate_manifest(Manifest.t()) :: :ok | {:error, Error.t()}
  def validate_manifest(%Manifest{} = manifest) do
    cond do
      is_nil(manifest.name) or manifest.name == "" ->
        {:error,
         Error.new(
           :validation_error,
           "Manifest name is required and cannot be empty"
         )}

      is_nil(manifest.version) or manifest.version == "" ->
        {:error,
         Error.new(
           :validation_error,
           "Manifest version is required and cannot be empty"
         )}

      not valid_capabilities?(manifest.capabilities) ->
        {:error,
         Error.new(
           :validation_error,
           "Manifest contains invalid capability: each capability must have a non-empty name and valid type"
         )}

      true ->
        :ok
    end
  end

  @doc """
  Filters manifests by provider.

  Returns all manifests that have the specified provider.

  ## Examples

      iex> anthropic_agents = Registry.filter_by_provider(registry, "anthropic")

  """
  @spec filter_by_provider(t(), String.t()) :: [Manifest.t()]
  def filter_by_provider(%__MODULE__{} = registry, provider) when is_binary(provider) do
    registry
    |> list()
    |> Enum.filter(&(&1.provider == provider))
  end

  @doc """
  Filters manifests by capability type.

  Returns all manifests that have at least one enabled capability of the specified type.

  ## Examples

      iex> tool_agents = Registry.filter_by_capability(registry, :tool)

  """
  @spec filter_by_capability(t(), atom()) :: [Manifest.t()]
  def filter_by_capability(%__MODULE__{} = registry, capability_type)
      when is_atom(capability_type) do
    registry
    |> list()
    |> Enum.filter(fn manifest ->
      Enum.any?(manifest.capabilities, fn cap ->
        cap.type == capability_type && cap.enabled
      end)
    end)
  end

  @doc """
  Converts the registry to a map suitable for JSON serialization.

  ## Examples

      iex> map = Registry.to_map(registry)
      %{"manifests" => [...], "metadata" => %{}}

  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = registry) do
    %{
      "manifests" =>
        registry.manifests
        |> Map.values()
        |> Enum.map(&Manifest.to_map/1),
      "metadata" => stringify_keys(registry.metadata)
    }
  end

  @doc """
  Reconstructs a registry from a map.

  ## Examples

      iex> {:ok, registry} = Registry.from_map(map)

  """
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) when is_map(map) do
    with {:ok, manifests} <- parse_manifests(map["manifests"]) do
      registry = %__MODULE__{
        manifests: manifests,
        metadata: atomize_keys(map["metadata"] || %{})
      }

      {:ok, registry}
    end
  end

  def from_map(_), do: {:error, Error.new(:validation_error, "Invalid registry map")}

  # Private helpers

  defp check_not_exists(registry, name) do
    if Map.has_key?(registry.manifests, name) do
      {:error, Error.new(:already_exists, "Manifest '#{name}' already exists in registry")}
    else
      :ok
    end
  end

  defp valid_capabilities?(capabilities) when is_list(capabilities) do
    Enum.all?(capabilities, fn
      %Capability{name: name, type: type} ->
        is_binary(name) and name != "" and Capability.valid_type?(type)

      _ ->
        false
    end)
  end

  defp valid_capabilities?(_), do: true

  defp parse_manifests(nil), do: {:ok, %{}}
  defp parse_manifests([]), do: {:ok, %{}}

  defp parse_manifests(manifests) when is_list(manifests) do
    results =
      Enum.reduce_while(manifests, {:ok, %{}}, fn manifest_map, {:ok, acc} ->
        case Manifest.from_map(manifest_map) do
          {:ok, manifest} ->
            {:cont, {:ok, Map.put(acc, manifest.name, manifest)}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    results
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_keys(other), do: other

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v), do: v

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_value(v)}
      {k, v} -> {k, atomize_value(v)}
    end)
  end

  defp atomize_keys(other), do: other

  defp atomize_value(v) when is_map(v), do: atomize_keys(v)
  defp atomize_value(v), do: v
end
