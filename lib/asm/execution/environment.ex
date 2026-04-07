defmodule ASM.Execution.Environment do
  @moduledoc """
  Normalized runtime environment and policy context for ASM execution.
  """

  alias ASM.Permission

  @valid_approval_postures [:manual, :auto, :none]
  @valid_keys [:workspace_root, :allowed_tools, :approval_posture, :permission_mode]
  @approval_to_permission %{
    manual: :default,
    auto: :auto,
    none: :bypass
  }

  @enforce_keys []
  defstruct workspace_root: nil,
            allowed_tools: [],
            approval_posture: nil,
            permission_mode: nil

  @type t :: %__MODULE__{
          workspace_root: String.t() | nil,
          allowed_tools: [String.t()],
          approval_posture: :manual | :auto | :none | nil,
          permission_mode: Permission.normalized_mode() | nil
        }

  @type validation_error ::
          {:unknown_execution_environment_fields, [term()]}
          | {:invalid_workspace_root, term()}
          | {:invalid_allowed_tools, term()}
          | {:invalid_approval_posture, term()}
          | {:invalid_permission_mode, term()}
          | {:invalid_execution_environment, term()}

  @spec keys() :: [atom(), ...]
  def keys, do: @valid_keys

  @spec new(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs \\ nil)

  def new(nil), do: {:ok, %__MODULE__{}}

  def new(%__MODULE__{} = environment), do: {:ok, environment}

  def new(attrs) do
    with {:ok, normalized_attrs} <- normalize_attrs(attrs) do
      {:ok,
       struct!(
         __MODULE__,
         workspace_root: Keyword.get(normalized_attrs, :workspace_root),
         allowed_tools: Keyword.get(normalized_attrs, :allowed_tools, []),
         approval_posture: Keyword.get(normalized_attrs, :approval_posture),
         permission_mode: Keyword.get(normalized_attrs, :permission_mode)
       )}
    end
  end

  @spec normalize_attrs(t() | keyword() | map() | nil) ::
          {:ok, keyword()} | {:error, validation_error()}
  def normalize_attrs(nil), do: {:ok, []}

  def normalize_attrs(%__MODULE__{} = environment), do: {:ok, to_attrs(environment)}

  def normalize_attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs
      |> keyword_present_attrs()
      |> normalize_present_attrs()
    else
      {:error, {:invalid_execution_environment, attrs}}
    end
  end

  def normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> map_present_attrs()
    |> normalize_present_attrs()
  end

  def normalize_attrs(other), do: {:error, {:invalid_execution_environment, other}}

  @spec to_attrs(t()) :: keyword()
  def to_attrs(%__MODULE__{} = environment) do
    [
      workspace_root: environment.workspace_root,
      allowed_tools: environment.allowed_tools,
      approval_posture: environment.approval_posture,
      permission_mode: environment.permission_mode
    ]
  end

  defp keyword_present_attrs(attrs) when is_list(attrs) do
    unknown =
      attrs
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @valid_keys))

    if unknown == [] do
      {:ok,
       Enum.reduce(@valid_keys, [], fn key, acc ->
         if Keyword.has_key?(attrs, key) do
           [{key, Keyword.get(attrs, key)} | acc]
         else
           acc
         end
       end)
       |> Enum.reverse()}
    else
      {:error, {:unknown_execution_environment_fields, unknown}}
    end
  end

  defp map_present_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      case normalize_input_key(key) do
        {:ok, normalized_key} ->
          {:cont, {:ok, [{normalized_key, value} | acc]}}

        :error ->
          {:halt, {:error, {:unknown_execution_environment_fields, [key]}}}
      end
    end)
    |> case do
      {:ok, values} ->
        {:ok, Enum.reverse(values)}

      {:error, {:unknown_execution_environment_fields, fields}} ->
        {:error, {:unknown_execution_environment_fields, Enum.uniq(fields)}}
    end
  end

  defp normalize_input_key(key) when key in @valid_keys, do: {:ok, key}

  defp normalize_input_key(key) when is_binary(key) do
    case key do
      "workspace_root" -> {:ok, :workspace_root}
      "allowed_tools" -> {:ok, :allowed_tools}
      "approval_posture" -> {:ok, :approval_posture}
      "permission_mode" -> {:ok, :permission_mode}
      _other -> :error
    end
  end

  defp normalize_input_key(_key), do: :error

  defp normalize_present_attrs({:error, _reason} = error), do: error

  defp normalize_present_attrs({:ok, attrs}) when is_list(attrs) do
    with {:ok, workspace_root} <- normalize_workspace_root(attrs),
         {:ok, allowed_tools} <- normalize_allowed_tools(attrs),
         {:ok, approval_posture} <- normalize_approval_posture(attrs),
         {:ok, permission_mode} <- normalize_permission_mode(attrs, approval_posture) do
      {:ok,
       []
       |> maybe_put(:workspace_root, workspace_root, Keyword.has_key?(attrs, :workspace_root))
       |> maybe_put(:allowed_tools, allowed_tools, Keyword.has_key?(attrs, :allowed_tools))
       |> maybe_put(
         :approval_posture,
         approval_posture,
         Keyword.has_key?(attrs, :approval_posture)
       )
       |> maybe_put(
         :permission_mode,
         permission_mode,
         Keyword.has_key?(attrs, :permission_mode) or
           (Keyword.has_key?(attrs, :approval_posture) and
              not Keyword.has_key?(attrs, :permission_mode) and
              not is_nil(permission_mode))
       )}
    end
  end

  defp normalize_workspace_root(attrs) when is_list(attrs) do
    if Keyword.has_key?(attrs, :workspace_root) do
      value = Keyword.get(attrs, :workspace_root)

      if is_nil(value) or (is_binary(value) and value != "") do
        {:ok, value}
      else
        {:error, {:invalid_workspace_root, value}}
      end
    else
      {:ok, nil}
    end
  end

  defp normalize_allowed_tools(attrs) when is_list(attrs) do
    if Keyword.has_key?(attrs, :allowed_tools) do
      attrs
      |> Keyword.get(:allowed_tools)
      |> normalize_string_list()
      |> case do
        {:ok, values} -> {:ok, values}
        {:error, reason} -> {:error, {:invalid_allowed_tools, reason}}
      end
    else
      {:ok, []}
    end
  end

  defp normalize_approval_posture(attrs) when is_list(attrs) do
    if Keyword.has_key?(attrs, :approval_posture) do
      case normalize_approval_posture_value(Keyword.get(attrs, :approval_posture)) do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, {:invalid_approval_posture, reason}}
      end
    else
      {:ok, nil}
    end
  end

  defp normalize_permission_mode(attrs, approval_posture) when is_list(attrs) do
    cond do
      Keyword.has_key?(attrs, :permission_mode) ->
        case normalize_permission_mode_value(Keyword.get(attrs, :permission_mode)) do
          {:ok, value} -> {:ok, value}
          {:error, reason} -> {:error, {:invalid_permission_mode, reason}}
        end

      Keyword.has_key?(attrs, :approval_posture) and not is_nil(approval_posture) ->
        {:ok, Map.get(@approval_to_permission, approval_posture)}

      true ->
        {:ok, nil}
    end
  end

  defp normalize_approval_posture_value(nil), do: {:ok, nil}

  defp normalize_approval_posture_value(value) when value in @valid_approval_postures,
    do: {:ok, value}

  defp normalize_approval_posture_value(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "manual" -> {:ok, :manual}
      "auto" -> {:ok, :auto}
      "none" -> {:ok, :none}
      _other -> {:error, value}
    end
  end

  defp normalize_approval_posture_value(value), do: {:error, value}

  defp normalize_permission_mode_value(nil), do: {:ok, nil}

  defp normalize_permission_mode_value(value) when is_atom(value) do
    if value in Permission.normalized_modes() do
      {:ok, value}
    else
      {:error, value}
    end
  end

  defp normalize_permission_mode_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "default" -> {:ok, :default}
      "auto" -> {:ok, :auto}
      "bypass" -> {:ok, :bypass}
      "plan" -> {:ok, :plan}
      _other -> {:error, value}
    end
  end

  defp normalize_permission_mode_value(value), do: {:error, value}

  defp normalize_string_list(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, {[], MapSet.new()}}, fn
      value, {:ok, {acc, seen}} when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            {:halt, {:error, :empty_entry}}

          MapSet.member?(seen, trimmed) ->
            {:cont, {:ok, {acc, seen}}}

          true ->
            {:cont, {:ok, {acc ++ [trimmed], MapSet.put(seen, trimmed)}}}
        end

      value, {:ok, {acc, seen}} when is_atom(value) ->
        normalized = Atom.to_string(value)

        if MapSet.member?(seen, normalized) do
          {:cont, {:ok, {acc, seen}}}
        else
          {:cont, {:ok, {acc ++ [normalized], MapSet.put(seen, normalized)}}}
        end

      value, _acc ->
        {:halt, {:error, {:invalid_entry, value}}}
    end)
    |> case do
      {:ok, {normalized, _seen}} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_string_list(value), do: {:error, {:invalid_list, value}}

  defp maybe_put(attrs, _key, _value, false), do: attrs
  defp maybe_put(attrs, key, value, true), do: Keyword.put(attrs, key, value)
end
