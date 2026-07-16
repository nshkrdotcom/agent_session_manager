defmodule ASM.ManagedSession do
  @moduledoc """
  Secret-free identity and lifecycle state for one governed provider session.

  Session and execution identity are opaque strings plus generations and
  fences. Provider process identifiers are never part of this contract.
  """

  @statuses ~w(allocated starting active draining completed failed cancelled ambiguous)
  @terminal_statuses ~w(completed failed cancelled ambiguous)
  @fields [
    :contract_version,
    :session_ref,
    :generation,
    :provider_account_ref,
    :credential_generation,
    :materialization_ref,
    :authority_ref,
    :target_ref,
    :runtime_gateway,
    :execution_ref,
    :provider_session_ref,
    :receipt_ref,
    :status,
    :fence,
    :row_version
  ]
  @required @fields -- [:execution_ref, :provider_session_ref, :receipt_ref]
  @enforce_keys @required
  defstruct @fields

  @type t :: %__MODULE__{}

  def new(%__MODULE__{} = session), do: validate(session)

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    session = %__MODULE__{
      contract_version: value(attrs, :contract_version, 1),
      session_ref: value(attrs, :session_ref),
      generation: value(attrs, :generation),
      provider_account_ref: value(attrs, :provider_account_ref),
      credential_generation: value(attrs, :credential_generation),
      materialization_ref: value(attrs, :materialization_ref),
      authority_ref: value(attrs, :authority_ref),
      target_ref: value(attrs, :target_ref),
      runtime_gateway: value(attrs, :runtime_gateway),
      execution_ref: value(attrs, :execution_ref),
      provider_session_ref: value(attrs, :provider_session_ref),
      receipt_ref: value(attrs, :receipt_ref),
      status: attrs |> value(:status) |> normalize_string(),
      fence: value(attrs, :fence),
      row_version: value(attrs, :row_version, 1)
    }

    if known_fields?(attrs) and safe_attrs?(attrs),
      do: validate(session),
      else: {:error, :invalid_managed_session}
  end

  def new(_attrs), do: {:error, :invalid_managed_session}

  def new!(attrs) do
    case new(attrs) do
      {:ok, session} -> session
      {:error, reason} -> raise ArgumentError, Atom.to_string(reason)
    end
  end

  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses
  def statuses, do: @statuses

  defp validate(%__MODULE__{} = session) do
    required_refs = [
      session.session_ref,
      session.provider_account_ref,
      session.materialization_ref,
      session.authority_ref,
      session.target_ref,
      session.runtime_gateway
    ]

    with true <- session.contract_version == 1,
         true <- Enum.all?(required_refs, &safe_ref?/1),
         true <- positive_integer?(session.generation),
         true <- positive_integer?(session.credential_generation),
         true <- session.status in @statuses,
         true <- non_negative_integer?(session.fence),
         true <- positive_integer?(session.row_version),
         true <- optional_ref?(session.execution_ref),
         true <- optional_ref?(session.provider_session_ref),
         true <- optional_ref?(session.receipt_ref),
         true <- coherent_state?(session) do
      {:ok, session}
    else
      _other -> {:error, :invalid_managed_session}
    end
  end

  defp coherent_state?(%__MODULE__{status: "allocated"} = session) do
    is_nil(session.execution_ref) and is_nil(session.provider_session_ref) and
      is_nil(session.receipt_ref)
  end

  defp coherent_state?(%__MODULE__{status: "starting"} = session) do
    is_nil(session.provider_session_ref) and is_nil(session.receipt_ref)
  end

  defp coherent_state?(%__MODULE__{status: status} = session)
       when status in ~w(active draining) do
    safe_ref?(session.execution_ref) and is_nil(session.receipt_ref)
  end

  defp coherent_state?(%__MODULE__{} = session) do
    terminal?(session) and safe_ref?(session.receipt_ref)
  end

  defp safe_attrs?(attrs) do
    forbidden = MapSet.new(~w(
      api_key auth_root authorization client_secret config_root credential env home
      material password pid private_key raw_credential refresh_token secret token
    ))

    Enum.all?(attrs, fn {key, nested} ->
      normalized = key |> to_string() |> String.downcase()

      not MapSet.member?(forbidden, normalized) and not String.starts_with?(normalized, "raw_") and
        not is_pid(nested) and not is_port(nested) and not is_reference(nested)
    end)
  end

  defp known_fields?(attrs) do
    allowed = MapSet.new(Enum.flat_map(@fields, &[&1, Atom.to_string(&1)]))
    Enum.all?(Map.keys(attrs), &MapSet.member?(allowed, &1))
  end

  defp optional_ref?(nil), do: true
  defp optional_ref?(value), do: safe_ref?(value)
  defp safe_ref?(value), do: is_binary(value) and String.trim(value) != "" and not path?(value)
  defp path?(value), do: String.starts_with?(value, ["/", "~/"])
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value
end

defmodule ASM.ManagedSession.Lifecycle do
  @moduledoc "Optimistic lifecycle validation for governed ASM sessions."

  alias ASM.ManagedSession

  @transitions %{
    "allocated" => ~w(starting cancelled),
    "starting" => ~w(active failed cancelled ambiguous),
    "active" => ~w(draining completed failed cancelled ambiguous),
    "draining" => ~w(completed failed cancelled ambiguous),
    "completed" => [],
    "failed" => [],
    "cancelled" => [],
    "ambiguous" => []
  }
  @update_fields [:execution_ref, :provider_session_ref, :receipt_ref]

  def transition(%ManagedSession{} = session, next_status, attrs)
      when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    next_status = normalize_string(next_status)

    with true <- known_fields?(attrs),
         true <- value(attrs, :expected_row_version) == session.row_version,
         true <- next_status in Map.fetch!(@transitions, session.status) do
      updates =
        Enum.reduce(@update_fields, Map.from_struct(session), fn field, acc ->
          case fetch(attrs, field) do
            {:ok, nested} -> Map.put(acc, field, nested)
            :error -> acc
          end
        end)

      result =
        updates
        |> Map.put(:status, next_status)
        |> Map.put(:row_version, session.row_version + 1)
        |> ManagedSession.new()

      case result do
        {:ok, _session} = ok -> ok
        {:error, _reason} -> {:error, :invalid_managed_session_transition}
      end
    else
      false -> {:error, :invalid_managed_session_transition}
    end
  end

  def transition(%ManagedSession{}, _next_status, _attrs),
    do: {:error, :invalid_managed_session_transition}

  defp known_fields?(attrs) do
    fields = [:expected_row_version | @update_fields]
    allowed = MapSet.new(Enum.flat_map(fields, &[&1, Atom.to_string(&1)]))
    Enum.all?(Map.keys(attrs), &MapSet.member?(allowed, &1))
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, nested} -> {:ok, nested}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value
end
