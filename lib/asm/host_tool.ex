defmodule ASM.HostTool do
  @moduledoc """
  Provider-neutral host dynamic tool contracts.

  Codex app-server renders `%Spec{}` values as upstream `dynamicTools` and maps
  dynamic tool JSON-RPC requests into `%Request{}` / `%Response{}` events.
  """

  @sensitive_metadata_fragments [
    "API_KEY",
    "AUTH",
    "BEARER",
    "CREDENTIAL",
    "PASSWORD",
    "SECRET",
    "TOKEN"
  ]

  @doc false
  @spec normalize_metadata(term()) :: {:ok, map()} | {:error, term()}
  def normalize_metadata(nil), do: {:ok, %{}}

  def normalize_metadata(metadata) when is_map(metadata) do
    sensitive_keys =
      metadata
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&sensitive_metadata_key?/1)
      |> Enum.uniq()

    if sensitive_keys == [] do
      {:ok, metadata}
    else
      {:error, {:sensitive_host_tool_metadata_keys, sensitive_keys}}
    end
  end

  def normalize_metadata(metadata), do: {:error, {:invalid_host_tool_metadata, metadata}}

  defp sensitive_metadata_key?(key) do
    normalized = String.upcase(key)
    Enum.any?(@sensitive_metadata_fragments, &String.contains?(normalized, &1))
  end

  defmodule Spec do
    @moduledoc "Host dynamic tool declaration."

    @enforce_keys [:name, :input_schema]
    defstruct name: nil,
              description: nil,
              input_schema: nil,
              output_schema: nil,
              metadata: %{}

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            input_schema: map(),
            output_schema: map() | nil,
            metadata: map()
          }

    @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, term()}
    def new(%__MODULE__{} = spec), do: {:ok, spec}

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      attrs = normalize_attrs(attrs)

      with {:ok, name} <- required_string(attrs, :name),
           {:ok, input_schema} <- required_map(attrs, :input_schema),
           {:ok, metadata} <- ASM.HostTool.normalize_metadata(Map.get(attrs, :metadata, %{})) do
        {:ok,
         %__MODULE__{
           name: name,
           description: optional_string(attrs, :description),
           input_schema: input_schema,
           output_schema: optional_map(attrs, :output_schema),
           metadata: metadata
         }}
      end
    end

    @spec new!(keyword() | map() | t()) :: t()
    def new!(attrs) do
      case new(attrs) do
        {:ok, spec} -> spec
        {:error, reason} -> raise ArgumentError, "invalid host tool spec: #{inspect(reason)}"
      end
    end

    @spec normalize_list([keyword() | map() | t()] | nil) :: {:ok, [t()]} | {:error, term()}
    def normalize_list(nil), do: {:ok, []}
    def normalize_list([]), do: {:ok, []}

    def normalize_list(specs) when is_list(specs) do
      Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, acc} ->
        case new(spec) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        {:error, reason} -> {:error, reason}
      end
    end

    def normalize_list(other), do: {:error, {:invalid_host_tools, other}}

    @spec to_dynamic_tool(t()) :: map()
    def to_dynamic_tool(%__MODULE__{} = spec) do
      %{
        "name" => spec.name,
        "description" => spec.description,
        "inputSchema" => spec.input_schema,
        "outputSchema" => spec.output_schema
      }
      |> drop_nil_values()
    end

    defp normalize_attrs(attrs) do
      attrs
      |> Enum.into(%{})
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        Map.put(acc, normalize_key(key), value)
      end)
    end

    defp normalize_key("name"), do: :name
    defp normalize_key("description"), do: :description
    defp normalize_key("input_schema"), do: :input_schema
    defp normalize_key("inputSchema"), do: :input_schema
    defp normalize_key("output_schema"), do: :output_schema
    defp normalize_key("outputSchema"), do: :output_schema
    defp normalize_key("metadata"), do: :metadata
    defp normalize_key(key) when is_atom(key), do: key
    defp normalize_key(key), do: key

    defp required_string(attrs, key) do
      case Map.get(attrs, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        value -> {:error, {:missing_required_string, key, value}}
      end
    end

    defp required_map(attrs, key) do
      case Map.get(attrs, key) do
        value when is_map(value) -> {:ok, value}
        value -> {:error, {:missing_required_map, key, value}}
      end
    end

    defp optional_string(attrs, key) do
      case Map.get(attrs, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end

    defp optional_map(attrs, key) do
      case Map.get(attrs, key) do
        value when is_map(value) -> value
        _other -> nil
      end
    end

    defp drop_nil_values(map) do
      Map.reject(map, fn {_key, value} -> is_nil(value) end)
    end
  end

  defmodule Request do
    @moduledoc "Host dynamic tool invocation request."

    @enforce_keys [:id, :session_id, :run_id, :provider, :tool_name]
    defstruct id: nil,
              session_id: nil,
              run_id: nil,
              provider: nil,
              provider_session_id: nil,
              provider_turn_id: nil,
              tool_name: nil,
              arguments: %{},
              raw: nil,
              metadata: %{}

    @type t :: %__MODULE__{
            id: String.t() | integer(),
            session_id: String.t(),
            run_id: String.t(),
            provider: atom(),
            provider_session_id: String.t() | nil,
            provider_turn_id: String.t() | nil,
            tool_name: String.t(),
            arguments: term(),
            raw: term(),
            metadata: map()
          }

    @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, term()}
    def new(%__MODULE__{} = request), do: {:ok, request}

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      attrs = Enum.into(attrs, %{})

      with {:ok, id} <- required_id(attrs, :id),
           {:ok, session_id} <- required_string(attrs, :session_id),
           {:ok, run_id} <- required_string(attrs, :run_id),
           {:ok, provider} <- required_atom(attrs, :provider),
           {:ok, tool_name} <- required_string(attrs, :tool_name),
           {:ok, metadata} <- ASM.HostTool.normalize_metadata(Map.get(attrs, :metadata, %{})) do
        {:ok,
         %__MODULE__{
           id: id,
           session_id: session_id,
           run_id: run_id,
           provider: provider,
           provider_session_id: optional_string(attrs, :provider_session_id),
           provider_turn_id: optional_string(attrs, :provider_turn_id),
           tool_name: tool_name,
           arguments: Map.get(attrs, :arguments, %{}),
           raw: Map.get(attrs, :raw),
           metadata: metadata
         }}
      end
    end

    @spec new!(keyword() | map() | t()) :: t()
    def new!(attrs) do
      case new(attrs) do
        {:ok, request} -> request
        {:error, reason} -> raise ArgumentError, "invalid host tool request: #{inspect(reason)}"
      end
    end

    defp required_id(attrs, key) do
      case Map.get(attrs, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        value when is_integer(value) -> {:ok, value}
        value -> {:error, {:missing_required_id, key, value}}
      end
    end

    defp required_string(attrs, key) do
      case Map.get(attrs, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        value -> {:error, {:missing_required_string, key, value}}
      end
    end

    defp required_atom(attrs, key) do
      case Map.get(attrs, key) do
        value when is_atom(value) -> {:ok, value}
        value -> {:error, {:missing_required_atom, key, value}}
      end
    end

    defp optional_string(attrs, key) do
      case Map.get(attrs, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end
  end

  defmodule Response do
    @moduledoc "Host dynamic tool invocation response."

    @enforce_keys [:request_id, :success?]
    defstruct request_id: nil,
              success?: false,
              output: nil,
              content_items: [],
              error: nil,
              metadata: %{}

    @type t :: %__MODULE__{
            request_id: String.t() | integer(),
            success?: boolean(),
            output: term(),
            content_items: [map()],
            error: term(),
            metadata: map()
          }

    @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, term()}
    def new(%__MODULE__{} = response), do: {:ok, response}

    def new(attrs) when is_list(attrs) or is_map(attrs) do
      attrs = normalize_attrs(attrs)

      with {:ok, request_id} <- required_id(attrs, :request_id),
           {:ok, success?} <- required_boolean(attrs, :success?),
           {:ok, metadata} <- ASM.HostTool.normalize_metadata(Map.get(attrs, :metadata, %{})) do
        {:ok,
         %__MODULE__{
           request_id: request_id,
           success?: success?,
           output: Map.get(attrs, :output),
           content_items: normalize_content_items(Map.get(attrs, :content_items, [])),
           error: Map.get(attrs, :error),
           metadata: metadata
         }}
      end
    end

    @spec new!(keyword() | map() | t()) :: t()
    def new!(attrs) do
      case new(attrs) do
        {:ok, response} -> response
        {:error, reason} -> raise ArgumentError, "invalid host tool response: #{inspect(reason)}"
      end
    end

    @spec to_dynamic_tool_response(t()) :: map()
    def to_dynamic_tool_response(%__MODULE__{} = response) do
      %{
        "success" => response.success?,
        "output" => encode_output(response.output),
        "contentItems" => response.content_items,
        "error" => response.error
      }
      |> Map.reject(fn
        {_key, nil} -> true
        {"contentItems", []} -> true
        {_key, _value} -> false
      end)
    end

    defp normalize_attrs(attrs) do
      attrs
      |> Enum.into(%{})
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        Map.put(acc, normalize_key(key), value)
      end)
    end

    defp normalize_key("request_id"), do: :request_id
    defp normalize_key("requestId"), do: :request_id
    defp normalize_key("success?"), do: :success?
    defp normalize_key("success"), do: :success?
    defp normalize_key("output"), do: :output
    defp normalize_key("content_items"), do: :content_items
    defp normalize_key("contentItems"), do: :content_items
    defp normalize_key("error"), do: :error
    defp normalize_key("metadata"), do: :metadata
    defp normalize_key(key) when is_atom(key), do: key
    defp normalize_key(key), do: key

    defp required_id(attrs, key) do
      case Map.get(attrs, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        value when is_integer(value) -> {:ok, value}
        value -> {:error, {:missing_required_id, key, value}}
      end
    end

    defp required_boolean(attrs, key) do
      case Map.get(attrs, key) do
        value when is_boolean(value) -> {:ok, value}
        value -> {:error, {:missing_required_boolean, key, value}}
      end
    end

    defp normalize_content_items(items) when is_list(items) do
      Enum.filter(items, &is_map/1)
    end

    defp normalize_content_items(_items), do: []

    defp encode_output(nil), do: nil
    defp encode_output(output) when is_binary(output), do: output

    defp encode_output(output) do
      Jason.encode!(output)
    rescue
      _error -> inspect(output)
    end
  end
end
