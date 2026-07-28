defmodule ASM.ProviderBackend.SDK.CodexReviewedApproval do
  @moduledoc false

  @metadata_key "asm_reviewed_codex_approval"
  @metadata_atom :asm_reviewed_codex_approval
  @required_keys [
    :effect_ref,
    :workspace_root,
    :relative_path,
    :reviewed_content,
    :content_digest
  ]
  @safe_relative_path ~r/\A[A-Za-z0-9._\/-]+\z/
  @max_content_bytes 65_536

  @spec prepare(nil | map(), atom() | nil) :: {:ok, nil | map()} | {:error, term()}
  def prepare(nil, _provider_permission_mode), do: {:ok, nil}

  def prepare(attrs, :auto_edit) when is_map(attrs) do
    with {:ok, normalized} <- normalize(attrs),
         :ok <- validate(normalized) do
      inner_command = inner_command(normalized)

      {:ok,
       normalized
       |> Map.drop([:reviewed_content])
       |> Map.merge(%{
         inner_command: inner_command,
         command: ~s(/bin/bash -lc "#{inner_command}"),
         execpolicy_amendment: ["/bin/bash", "-lc", inner_command]
       })}
    end
  end

  def prepare(%{}, _provider_permission_mode),
    do: {:error, :reviewed_approval_requires_auto_edit}

  def prepare(_attrs, _provider_permission_mode), do: {:error, :invalid_reviewed_approval}

  @spec thread_option_attrs(nil | map()) :: keyword()
  def thread_option_attrs(nil), do: []

  def thread_option_attrs(%{} = binding) do
    [
      approval_hook: __MODULE__,
      metadata: %{@metadata_key => binding}
    ]
  end

  @spec prompt(String.t(), nil | map()) :: String.t()
  def prompt(prompt, nil) when is_binary(prompt), do: prompt

  def prompt(prompt, %{inner_command: inner_command}) when is_binary(prompt) do
    prompt <>
      """

      The exact provider command below is already covered by the accepted review.
      Execute exactly this one command, with no additions or substitutions:

      #{inner_command}

      Do not run a verification command or request broader permissions. The caller
      verifies the isolated workspace after the provider turn.
      """
  end

  def review_tool(_event, _context, _opts),
    do: {:deny, "reviewed effect does not authorize dynamic tools"}

  def review_file(_event, _context, _opts),
    do: {:deny, "file approval lacks the exact reviewed command binding"}

  def review_permissions(_event, _context, _opts),
    do: {:deny, "reviewed effect does not authorize additional permissions"}

  def review_command(event, context, _opts) when is_map(event) and is_map(context) do
    with {:ok, binding} <- fetch_binding(context),
         :ok <- exact_command?(event, binding),
         :ok <- first_approval?(event, binding) do
      :allow
    else
      {:error, reason} -> {:deny, reason}
    end
  end

  def review_command(_event, _context, _opts),
    do: {:deny, "invalid reviewed command approval"}

  defp normalize(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_key(key) do
        nil -> {:halt, {:error, {:unknown_reviewed_approval_field, key}}}
        normalized -> {:cont, {:ok, Map.put(acc, normalized, value)}}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: if(key in @required_keys, do: key)

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@required_keys, &(Atom.to_string(&1) == key))
  end

  defp normalize_key(_key), do: nil

  defp validate(binding) do
    workspace_root = Map.get(binding, :workspace_root)
    relative_path = Map.get(binding, :relative_path)
    reviewed_content = Map.get(binding, :reviewed_content)
    content_digest = Map.get(binding, :content_digest)
    effect_ref = Map.get(binding, :effect_ref)

    cond do
      not present_string?(effect_ref) ->
        {:error, :invalid_reviewed_effect_ref}

      not absolute_normalized_path?(workspace_root) ->
        {:error, :invalid_reviewed_workspace_root}

      not safe_relative_path?(relative_path) ->
        {:error, :invalid_reviewed_relative_path}

      not inside_workspace?(workspace_root, relative_path) ->
        {:error, :reviewed_path_outside_workspace}

      not is_binary(reviewed_content) or not String.valid?(reviewed_content) or
          byte_size(reviewed_content) > @max_content_bytes ->
        {:error, :invalid_reviewed_content}

      digest(reviewed_content) != content_digest ->
        {:error, :reviewed_content_digest_mismatch}

      true ->
        :ok
    end
  end

  defp inner_command(binding) do
    encoded = Base.encode64(Map.fetch!(binding, :reviewed_content))
    relative_path = Map.fetch!(binding, :relative_path)

    "printf '%s' '#{encoded}' | base64 --decode > '#{relative_path}'"
  end

  defp fetch_binding(context) do
    metadata = Map.get(context, :metadata, Map.get(context, "metadata", %{}))

    case Map.get(metadata, @metadata_key, Map.get(metadata, @metadata_atom)) do
      %{} = binding -> {:ok, binding}
      _other -> {:error, "reviewed command binding is missing"}
    end
  end

  defp exact_command?(event, binding) do
    inner_command = Map.fetch!(binding, :inner_command)
    execpolicy_amendment = event_value(event, :proposed_execpolicy_amendment)

    cond do
      event_value(event, :command) != Map.fetch!(binding, :command) ->
        {:error, "command does not match the reviewed operation"}

      event_value(event, :cwd) != Map.fetch!(binding, :workspace_root) ->
        {:error, "command workspace does not match the reviewed operation"}

      not exact_command_actions?(event_value(event, :command_actions), inner_command) ->
        {:error, "command actions do not match the reviewed operation"}

      execpolicy_amendment not in [nil, [], Map.fetch!(binding, :execpolicy_amendment)] ->
        {:error, "exec policy amendment does not match the reviewed operation"}

      not empty_value?(event_value(event, :network_approval_context)) ->
        {:error, "reviewed operation does not authorize network access"}

      not empty_value?(event_value(event, :proposed_network_policy_amendments)) ->
        {:error, "reviewed operation does not authorize network policy amendments"}

      not empty_value?(event_value(event, :additional_permissions)) ->
        {:error, "reviewed operation does not authorize additional permissions"}

      not empty_value?(event_value(event, :skill_metadata)) ->
        {:error, "reviewed operation does not authorize skills"}

      true ->
        :ok
    end
  end

  defp exact_command_actions?([action], inner_command) when is_map(action) do
    action_keys =
      action
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    action_keys == ["command", "type"] and
      event_value(action, :type) == "unknown" and
      event_value(action, :command) == inner_command
  end

  defp exact_command_actions?(_actions, _inner_command), do: false

  defp first_approval?(event, binding) do
    key =
      {__MODULE__, Map.fetch!(binding, :effect_ref), event_value(event, :thread_id),
       event_value(event, :turn_id)}

    if Process.get(key) do
      {:error, "reviewed command approval was already consumed"}
    else
      Process.put(key, true)
      :ok
    end
  end

  defp empty_value?(nil), do: true
  defp empty_value?(false), do: true
  defp empty_value?([]), do: true

  defp empty_value?(%{} = value) do
    value
    |> Map.drop([:__struct__])
    |> Map.values()
    |> Enum.all?(&empty_value?/1)
  end

  defp empty_value?(_value), do: false

  defp event_value(%{} = map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp safe_relative_path?(path) when is_binary(path) do
    Regex.match?(@safe_relative_path, path) and
      path != "" and
      Path.type(path) == :relative and
      Enum.all?(Path.split(path), &(&1 not in ["", ".", ".."]))
  end

  defp safe_relative_path?(_path), do: false

  defp inside_workspace?(workspace_root, relative_path) do
    target = Path.expand(relative_path, workspace_root)
    target != workspace_root and String.starts_with?(target, workspace_root <> "/")
  end

  defp absolute_normalized_path?(path) when is_binary(path) do
    Path.type(path) == :absolute and Path.expand(path) == path
  end

  defp absolute_normalized_path?(_path), do: false

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
