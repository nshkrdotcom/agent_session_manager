defmodule ASM.InferenceEndpoint.ConsumerManifest do
  @moduledoc """
  Shared consumer manifest contract for the ASM inference endpoint facade.
  """

  defstruct contract_version: "inference.v1",
            consumer: nil,
            accepted_runtime_kinds: [:task],
            accepted_management_modes: [:jido_managed],
            accepted_protocols: [:openai_chat_completions],
            required_capabilities: %{},
            optional_capabilities: %{},
            constraints: %{},
            metadata: %{}

  @type t :: %__MODULE__{
          contract_version: String.t(),
          consumer: atom() | String.t() | nil,
          accepted_runtime_kinds: [atom()],
          accepted_management_modes: [atom()],
          accepted_protocols: [atom()],
          required_capabilities: map(),
          optional_capabilities: map(),
          constraints: map(),
          metadata: map()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    {:ok,
     struct(__MODULE__, %{
       contract_version:
         value(attrs, :contract_version, "inference.v1") |> normalize_string("contract_version"),
       consumer: value(attrs, :consumer),
       accepted_runtime_kinds: value(attrs, :accepted_runtime_kinds, [:task]),
       accepted_management_modes: value(attrs, :accepted_management_modes, [:jido_managed]),
       accepted_protocols: value(attrs, :accepted_protocols, [:openai_chat_completions]),
       required_capabilities: value(attrs, :required_capabilities, %{}) |> normalize_map(),
       optional_capabilities: value(attrs, :optional_capabilities, %{}) |> normalize_map(),
       constraints: value(attrs, :constraints, %{}) |> normalize_map(),
       metadata: value(attrs, :metadata, %{}) |> normalize_map()
     })}
  rescue
    error in ArgumentError -> {:error, error}
  end

  def new(_attrs), do: {:error, :invalid_consumer_manifest}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, %__MODULE__{} = manifest} -> manifest
      {:error, reason} -> raise ArgumentError, "invalid consumer manifest: #{inspect(reason)}"
    end
  end

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp normalize_string(value, _field_name) when is_binary(value) and value != "", do: value

  defp normalize_string(value, field_name) do
    raise ArgumentError, "#{field_name} must be a non-empty string, got: #{inspect(value)}"
  end

  defp normalize_map(value) when is_map(value), do: Map.new(value)

  defp normalize_map(value) do
    raise ArgumentError, "expected a map, got: #{inspect(value)}"
  end
end

defmodule ASM.InferenceEndpoint.EndpointDescriptor do
  @moduledoc """
  Shared endpoint publication contract for CLI-backed ASM inference routes.
  """

  defstruct contract_version: "inference.v1",
            endpoint_id: nil,
            runtime_kind: :task,
            management_mode: :jido_managed,
            target_class: :cli_endpoint,
            protocol: :openai_chat_completions,
            base_url: nil,
            headers: %{},
            provider_identity: nil,
            model_identity: nil,
            source_runtime: :agent_session_manager,
            source_runtime_ref: nil,
            lease_ref: nil,
            health_ref: nil,
            boundary_ref: nil,
            capabilities: %{},
            metadata: %{}

  @type t :: %__MODULE__{
          contract_version: String.t(),
          endpoint_id: String.t(),
          runtime_kind: :client | :task | :service,
          management_mode: atom(),
          target_class: :cloud_provider | :cli_endpoint | :self_hosted_endpoint,
          protocol: atom(),
          base_url: String.t(),
          headers: %{optional(String.t()) => String.t()},
          provider_identity: atom() | String.t() | nil,
          model_identity: String.t() | nil,
          source_runtime: atom(),
          source_runtime_ref: String.t() | nil,
          lease_ref: String.t() | nil,
          health_ref: String.t() | nil,
          boundary_ref: String.t() | nil,
          capabilities: map(),
          metadata: map()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    {:ok,
     struct(__MODULE__, %{
       contract_version:
         value(attrs, :contract_version, "inference.v1") |> normalize_string("contract_version"),
       endpoint_id: value(attrs, :endpoint_id) |> normalize_string("endpoint_id"),
       runtime_kind: value(attrs, :runtime_kind, :task),
       management_mode: value(attrs, :management_mode, :jido_managed),
       target_class: value(attrs, :target_class, :cli_endpoint),
       protocol: value(attrs, :protocol, :openai_chat_completions),
       base_url: value(attrs, :base_url) |> normalize_string("base_url"),
       headers: value(attrs, :headers, %{}) |> normalize_headers(),
       provider_identity: value(attrs, :provider_identity),
       model_identity: value(attrs, :model_identity),
       source_runtime: value(attrs, :source_runtime, :agent_session_manager),
       source_runtime_ref: value(attrs, :source_runtime_ref),
       lease_ref: value(attrs, :lease_ref),
       health_ref: value(attrs, :health_ref),
       boundary_ref: value(attrs, :boundary_ref),
       capabilities: value(attrs, :capabilities, %{}) |> normalize_map(),
       metadata: value(attrs, :metadata, %{}) |> normalize_map()
     })}
  rescue
    error in ArgumentError -> {:error, error}
  end

  def new(_attrs), do: {:error, :invalid_endpoint_descriptor}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, %__MODULE__{} = descriptor} -> descriptor
      {:error, reason} -> raise ArgumentError, "invalid endpoint descriptor: #{inspect(reason)}"
    end
  end

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp normalize_string(nil, _field_name), do: nil
  defp normalize_string(value, _field_name) when is_binary(value) and value != "", do: value

  defp normalize_string(value, field_name) do
    raise ArgumentError, "#{field_name} must be a non-empty string, got: #{inspect(value)}"
  end

  defp normalize_headers(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, header_value} ->
      {to_string(key), to_string(header_value)}
    end)
  end

  defp normalize_headers(value) do
    raise ArgumentError, "headers must be a map, got: #{inspect(value)}"
  end

  defp normalize_map(value) when is_map(value), do: Map.new(value)

  defp normalize_map(value) do
    raise ArgumentError, "expected a map, got: #{inspect(value)}"
  end
end

defmodule ASM.InferenceEndpoint.BackendManifest do
  @moduledoc """
  Shared backend manifest contract for the ASM CLI inference endpoint facade.
  """

  defstruct contract_version: "inference.v1",
            backend: :asm_inference_endpoint,
            runtime_kind: :task,
            management_modes: [:jido_managed],
            startup_kind: :spawned,
            protocols: [:openai_chat_completions],
            capabilities: %{streaming?: false, tool_calling?: false, embeddings?: :unknown},
            supported_surfaces: [:local_subprocess, :ssh_exec, :guest_bridge],
            resource_profile: %{},
            metadata: %{}

  @type t :: %__MODULE__{
          contract_version: String.t(),
          backend: atom(),
          runtime_kind: :task | :service,
          management_modes: [atom()],
          startup_kind: atom() | nil,
          protocols: [atom()],
          capabilities: map(),
          supported_surfaces: [atom()],
          resource_profile: map(),
          metadata: map()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    {:ok,
     struct(__MODULE__, %{
       contract_version:
         value(attrs, :contract_version, "inference.v1") |> normalize_string("contract_version"),
       backend: value(attrs, :backend, :asm_inference_endpoint),
       runtime_kind: value(attrs, :runtime_kind, :task),
       management_modes: value(attrs, :management_modes, [:jido_managed]),
       startup_kind: value(attrs, :startup_kind, :spawned),
       protocols: value(attrs, :protocols, [:openai_chat_completions]),
       capabilities:
         value(attrs, :capabilities, %{
           streaming?: false,
           tool_calling?: false,
           embeddings?: :unknown
         })
         |> normalize_capabilities(),
       supported_surfaces:
         value(attrs, :supported_surfaces, [:local_subprocess, :ssh_exec, :guest_bridge]),
       resource_profile: value(attrs, :resource_profile, %{}) |> normalize_map(),
       metadata: value(attrs, :metadata, %{}) |> normalize_map()
     })}
  rescue
    error in ArgumentError -> {:error, error}
  end

  def new(_attrs), do: {:error, :invalid_backend_manifest}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, %__MODULE__{} = manifest} -> manifest
      {:error, reason} -> raise ArgumentError, "invalid backend manifest: #{inspect(reason)}"
    end
  end

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp normalize_string(value, _field_name) when is_binary(value) and value != "", do: value

  defp normalize_string(value, field_name) do
    raise ArgumentError, "#{field_name} must be a non-empty string, got: #{inspect(value)}"
  end

  defp normalize_capabilities(value) when is_map(value) do
    %{
      streaming?: capability_value(value, :streaming?, false),
      tool_calling?: capability_value(value, :tool_calling?, false),
      embeddings?: capability_value(value, :embeddings?, :unknown)
    }
  end

  defp normalize_capabilities(value) do
    raise ArgumentError, "capabilities must be a map, got: #{inspect(value)}"
  end

  defp capability_value(map, key, default) do
    map
    |> Map.get(key, Map.get(map, Atom.to_string(key), default))
    |> normalize_capability(default)
  end

  defp normalize_capability(value, _default) when is_boolean(value) or value == :unknown,
    do: value

  defp normalize_capability("unknown", _default), do: :unknown

  defp normalize_capability(value, _default) do
    raise ArgumentError, "invalid capability value: #{inspect(value)}"
  end

  defp normalize_map(value) when is_map(value), do: Map.new(value)

  defp normalize_map(value) do
    raise ArgumentError, "expected a map, got: #{inspect(value)}"
  end
end

defmodule ASM.InferenceEndpoint.CompatibilityResult do
  @moduledoc """
  Shared compatibility result contract for ASM endpoint publication.
  """

  defstruct contract_version: "inference.v1",
            compatible?: false,
            reason: :unresolved,
            resolved_runtime_kind: nil,
            resolved_management_mode: nil,
            resolved_protocol: nil,
            warnings: [],
            missing_requirements: [],
            metadata: %{}

  @type t :: %__MODULE__{
          contract_version: String.t(),
          compatible?: boolean(),
          reason: atom(),
          resolved_runtime_kind: atom() | nil,
          resolved_management_mode: atom() | nil,
          resolved_protocol: atom() | nil,
          warnings: [atom()],
          missing_requirements: [atom()],
          metadata: map()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    {:ok,
     struct(__MODULE__, %{
       contract_version:
         value(attrs, :contract_version, "inference.v1") |> normalize_string("contract_version"),
       compatible?: value(attrs, :compatible?, false),
       reason: value(attrs, :reason, :unresolved),
       resolved_runtime_kind: value(attrs, :resolved_runtime_kind),
       resolved_management_mode: value(attrs, :resolved_management_mode),
       resolved_protocol: value(attrs, :resolved_protocol),
       warnings: value(attrs, :warnings, []),
       missing_requirements: value(attrs, :missing_requirements, []),
       metadata: value(attrs, :metadata, %{}) |> normalize_map()
     })}
  rescue
    error in ArgumentError -> {:error, error}
  end

  def new(_attrs), do: {:error, :invalid_compatibility_result}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, %__MODULE__{} = result} -> result
      {:error, reason} -> raise ArgumentError, "invalid compatibility result: #{inspect(reason)}"
    end
  end

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp normalize_string(value, _field_name) when is_binary(value) and value != "", do: value

  defp normalize_string(value, field_name) do
    raise ArgumentError, "#{field_name} must be a non-empty string, got: #{inspect(value)}"
  end

  defp normalize_map(value) when is_map(value), do: Map.new(value)

  defp normalize_map(value) do
    raise ArgumentError, "expected a map, got: #{inspect(value)}"
  end
end
