defmodule ASM.RuntimeAuth.ManagedBinding do
  @moduledoc """
  Secret-free binding between one ASM managed-session generation and one
  Jido credential materialization.

  Jido owns lease redemption and the transient `SecretMaterial`. ASM retains
  only the exact identity, generation, authority, target, workspace digest,
  and expiry needed to prevent a live session from switching accounts or
  being reused after its materialization has closed.
  """

  alias ASM.{Error, ManagedSession, RuntimeAuth}

  @request_fields [
    :materialization_ref,
    :lease_id,
    :account,
    :effect_ref,
    :operation_ref,
    :authority_ref,
    :endpoint_ref,
    :target_ref,
    :issued_at,
    :expires_at
  ]
  @account_fields [
    :provider_family,
    :account_ref,
    :tenant_id,
    :connection_id,
    :endpoint_ref,
    :quota_scope_ref,
    :generation,
    :fence
  ]
  @material_fields [
    :materialization_ref,
    :provider_family,
    :account_ref,
    :generation,
    :payload
  ]
  @gateway_callbacks [
    start_session: 1,
    send_input: 2,
    end_input: 1,
    info: 1,
    subscribe: 2,
    cancel: 2,
    terminate: 2
  ]
  @managed_override_keys [
    :access_token,
    :api_key,
    :auth_root,
    :auth_token,
    :authorization,
    :authorization_header,
    :base_url,
    :cli_path,
    :cmd,
    :command,
    :config_root,
    :config_values,
    :codex_home,
    :credential,
    :cwd,
    :env,
    :environment,
    :headers,
    :home,
    :oauth_token,
    :password,
    :private_key,
    :process_env,
    :provider_backend,
    :raw_credential,
    :refresh_token,
    :secret,
    :token,
    :token_file,
    :working_directory
  ]
  @secret_key_fragments ~w(
    access_token api_key auth_token authorization client_secret credential password
    private_key raw_credential refresh_token secret token
  )

  @enforce_keys [
    :asm_session_id,
    :session_ref,
    :session_generation,
    :provider_family,
    :provider_account_ref,
    :credential_generation,
    :materialization_ref,
    :lease_ref,
    :authority_ref,
    :target_ref,
    :endpoint_ref,
    :effect_ref,
    :operation_ref,
    :execution_context_ref,
    :connector_instance_ref,
    :connector_binding_ref,
    :operation_policy_ref,
    :native_auth_assertion_ref,
    :workspace_ref,
    :workspace_digest,
    :runtime_gateway_ref,
    :issued_at,
    :expires_at,
    :fence
  ]
  defstruct @enforce_keys ++ [:runtime_gateway_module]

  @type t :: %__MODULE__{
          asm_session_id: String.t(),
          session_ref: String.t(),
          session_generation: pos_integer(),
          provider_family: String.t(),
          provider_account_ref: String.t(),
          credential_generation: pos_integer(),
          materialization_ref: String.t(),
          lease_ref: String.t(),
          authority_ref: String.t(),
          target_ref: String.t(),
          endpoint_ref: String.t(),
          effect_ref: String.t(),
          operation_ref: String.t(),
          execution_context_ref: String.t(),
          connector_instance_ref: String.t(),
          connector_binding_ref: String.t(),
          operation_policy_ref: String.t(),
          native_auth_assertion_ref: String.t(),
          workspace_ref: String.t(),
          workspace_digest: String.t(),
          runtime_gateway_ref: String.t(),
          runtime_gateway_module: module() | nil,
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          fence: non_neg_integer()
        }

  @spec new(atom(), RuntimeAuth.t(), keyword()) :: {:ok, t() | nil} | {:error, Error.t()}
  def new(provider, %RuntimeAuth{} = runtime_auth, opts)
      when is_atom(provider) and is_list(opts) do
    case Keyword.get(opts, :managed_session) do
      nil ->
        {:ok, nil}

      managed_session ->
        with :ok <- require_governed(runtime_auth, provider),
             {:ok, managed_session} <- normalize_managed_session(managed_session, provider),
             {:ok, request} <-
               normalize_contract(
                 Keyword.get(opts, :materialization_request),
                 @request_fields,
                 :materialization_request,
                 provider
               ),
             {:ok, account} <-
               normalize_contract(
                 value(request, :account),
                 @account_fields,
                 :managed_account_ref,
                 provider
               ),
             {:ok, material} <-
               normalize_contract(
                 Keyword.get(opts, :secret_material),
                 @material_fields,
                 :secret_material,
                 provider
               ),
             {:ok, workspace_root} <- workspace_root(opts, material, provider),
             {:ok, runtime_gateway_module} <- runtime_gateway_module(opts, provider),
             :ok <- reject_managed_overrides(opts, provider),
             :ok <-
               validate_exact(provider, runtime_auth, managed_session, request, account, material),
             :ok <- validate_time_window(request, provider),
             {:ok, workspace_ref} <- workspace_ref(opts, workspace_root, provider),
             :ok <- validate_runtime_gateway_ref(opts, managed_session, provider) do
          {:ok,
           %__MODULE__{
             asm_session_id: runtime_auth.execution_context.session_id,
             session_ref: managed_session.session_ref,
             session_generation: managed_session.generation,
             provider_family: provider_family(account),
             provider_account_ref: managed_session.provider_account_ref,
             credential_generation: managed_session.credential_generation,
             materialization_ref: managed_session.materialization_ref,
             lease_ref: value(request, :lease_id),
             authority_ref: managed_session.authority_ref,
             target_ref: managed_session.target_ref,
             endpoint_ref: value(request, :endpoint_ref),
             effect_ref: value(request, :effect_ref),
             operation_ref: value(request, :operation_ref),
             execution_context_ref: runtime_auth.execution_context.ref,
             connector_instance_ref: runtime_auth.connector_instance.ref,
             connector_binding_ref: runtime_auth.connector_binding.ref,
             operation_policy_ref: runtime_auth.connector_binding.operation_policy_ref,
             native_auth_assertion_ref: runtime_auth.connector_binding.native_auth_assertion_ref,
             workspace_ref: workspace_ref,
             workspace_digest: workspace_digest(workspace_root),
             runtime_gateway_ref: managed_session.runtime_gateway,
             runtime_gateway_module: runtime_gateway_module,
             issued_at: value(request, :issued_at),
             expires_at: value(request, :expires_at),
             fence: managed_session.fence
           }}
        end
    end
  end

  @spec revalidate(t(), RuntimeAuth.t(), keyword()) :: :ok | {:error, Error.t()}
  def revalidate(%__MODULE__{} = binding, %RuntimeAuth{} = runtime_auth, opts)
      when is_list(opts) do
    with :ok <- active(binding),
         :ok <- validate_runtime_auth_binding(binding, runtime_auth),
         :ok <- reject_managed_overrides(opts, runtime_auth.execution_context.provider),
         :ok <- reject_identity_rebinding(binding, opts, runtime_auth.execution_context.provider),
         :ok <- validate_optional_bundle(binding, runtime_auth, opts) do
      :ok
    end
  end

  @spec active(t(), DateTime.t()) :: :ok | {:error, Error.t()}
  def active(%__MODULE__{} = binding, now \\ DateTime.utc_now()) do
    if DateTime.compare(binding.expires_at, now) == :gt do
      :ok
    else
      {:error,
       managed_error(
         :expired,
         "managed session materialization has expired",
         %{materialization_ref: binding.materialization_ref, expires_at: binding.expires_at}
       )}
    end
  end

  @spec remaining_ms(t(), DateTime.t()) :: non_neg_integer()
  def remaining_ms(%__MODULE__{} = binding, now \\ DateTime.utc_now()) do
    max(DateTime.diff(binding.expires_at, now, :millisecond), 0)
  end

  @spec authorize_revocation(t(), map() | keyword()) :: :ok | {:error, Error.t()}
  def authorize_revocation(%__MODULE__{} = binding, revocation) do
    attrs = attrs(revocation)
    lease_scope = value(attrs, :lease_scope, %{}) |> attrs()

    required_checks = [
      {:lease_ref, binding.lease_ref, value(attrs, :lease_ref)},
      {:workspace_ref, binding.workspace_ref, value(attrs, :workspace_ref)}
    ]

    optional_checks = [
      {:provider_account_ref, binding.provider_account_ref,
       value(lease_scope, :provider_account_ref) || value(attrs, :provider_account_ref)},
      {:credential_generation, binding.credential_generation,
       value(lease_scope, :credential_generation) || value(lease_scope, :generation) ||
         value(attrs, :credential_generation)},
      {:authority_ref, binding.authority_ref,
       value(lease_scope, :authority_ref) || value(attrs, :authority_ref)}
    ]

    cond do
      not is_map(attrs) ->
        {:error,
         managed_error(:invalid_revocation, "managed session revocation must be a map", %{})}

      not present?(value(attrs, :lease_ref)) ->
        {:error,
         managed_error(
           :invalid_revocation,
           "managed session revocation requires a lease_ref",
           %{missing: [:lease_ref]}
         )}

      secret_paths(attrs) != [] ->
        {:error,
         managed_error(
           :invalid_revocation,
           "managed session revocation must remain secret-free",
           %{forbidden_paths: secret_paths(attrs)}
         )}

      value(attrs, :lease_status) not in [
        :revoked,
        :rejected_after_revocation,
        "revoked",
        "rejected_after_revocation"
      ] ->
        {:error,
         managed_error(
           :invalid_revocation,
           "managed session revocation requires a terminal revoked lease status",
           %{}
         )}

      mismatch = Enum.find(required_checks, &mismatch?/1) ->
        {field, _expected, _actual} = mismatch

        {:error,
         managed_error(
           :revocation_mismatch,
           "managed session revocation does not match the pinned materialization",
           %{field: field}
         )}

      mismatch = Enum.find(optional_checks, &optional_mismatch?/1) ->
        {field, _expected, _actual} = mismatch

        {:error,
         managed_error(
           :revocation_mismatch,
           "managed session revocation does not match the pinned materialization",
           %{field: field}
         )}

      true ->
        :ok
    end
  end

  @spec to_metadata(t()) :: map()
  def to_metadata(%__MODULE__{} = binding) do
    binding
    |> Map.from_struct()
    |> Map.drop([:runtime_gateway_module])
    |> Map.put(:managed?, true)
  end

  @spec material_payload(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def material_payload(opts) when is_list(opts) do
    provider = Keyword.get(opts, :provider)

    case Keyword.get(opts, :secret_material) do
      material when is_map(material) ->
        case value(material, :payload) do
          payload when is_map(payload) and map_size(payload) > 0 ->
            {:ok, payload}

          _other ->
            {:error,
             managed_error(:invalid_material, "secret material payload is missing", %{}, provider)}
        end

      _other ->
        {:error, managed_error(:invalid_material, "secret material is missing", %{}, provider)}
    end
  end

  defp validate_optional_bundle(binding, runtime_auth, opts) do
    fields = [:managed_session, :materialization_request, :secret_material]

    if Enum.any?(fields, &Keyword.has_key?(opts, &1)) do
      if Enum.all?(fields, &Keyword.has_key?(opts, &1)) do
        provider = runtime_auth.execution_context.provider

        with {:ok, candidate} <- new(provider, %{runtime_auth | managed_binding: nil}, opts),
             true <- same_binding?(binding, candidate) do
          :ok
        else
          false ->
            {:error,
             managed_error(
               :materialization_mismatch,
               "managed session cannot replace its pinned materialization",
               %{session_ref: binding.session_ref},
               provider
             )}

          {:error, %Error{} = error} ->
            {:error, error}
        end
      else
        {:error,
         managed_error(
           :incomplete_materialization,
           "managed session revalidation requires session, request, and secret material together",
           %{required: fields},
           runtime_auth.execution_context.provider
         )}
      end
    else
      :ok
    end
  end

  defp same_binding?(left, right) do
    Map.drop(Map.from_struct(left), [:runtime_gateway_module]) ==
      Map.drop(Map.from_struct(right), [:runtime_gateway_module]) and
      compatible_gateway_modules?(left.runtime_gateway_module, right.runtime_gateway_module)
  end

  defp compatible_gateway_modules?(nil, _right), do: true
  defp compatible_gateway_modules?(_left, nil), do: true
  defp compatible_gateway_modules?(left, right), do: left == right

  defp require_governed(runtime_auth, provider) do
    if RuntimeAuth.governed_authority?(runtime_auth) do
      :ok
    else
      {:error,
       managed_error(
         :governed_authority_required,
         "managed session requires complete governed runtime authority",
         %{},
         provider
       )}
    end
  end

  defp normalize_managed_session(session, provider) do
    case ManagedSession.new(session) do
      {:ok, %ManagedSession{status: status} = normalized}
      when status in ["allocated", "starting", "active"] ->
        {:ok, normalized}

      {:ok, %ManagedSession{status: status}} ->
        {:error,
         managed_error(
           :invalid_session_state,
           "managed session materialization cannot attach in its current lifecycle state",
           %{status: status},
           provider
         )}

      {:error, _reason} ->
        {:error,
         managed_error(
           :invalid_managed_session,
           "invalid managed session contract",
           %{},
           provider
         )}
    end
  end

  defp normalize_contract(value, fields, label, provider) do
    attrs = attrs(value)

    cond do
      not is_map(attrs) ->
        {:error, managed_error(:invalid_contract, "invalid #{label} contract", %{}, provider)}

      not known_fields?(attrs, fields) ->
        {:error,
         managed_error(
           :invalid_contract,
           "invalid #{label} contract fields",
           %{unknown_fields: unknown_fields(attrs, fields)},
           provider
         )}

      contains_runtime_handle?(attrs) ->
        {:error,
         managed_error(
           :invalid_contract,
           "#{label} cannot contain process, port, or reference identity",
           %{},
           provider
         )}

      true ->
        {:ok, attrs}
    end
  end

  defp validate_exact(provider, runtime_auth, session, request, account, material) do
    binding = runtime_auth.connector_binding
    provider_family = provider_family(account)

    checks = [
      {:provider_family, Atom.to_string(provider), provider_family},
      {:material_provider_family, provider_family,
       normalize_family(value(material, :provider_family))},
      {:provider_account_ref, runtime_auth.provider_account_identity.ref,
       session.provider_account_ref},
      {:request_account_ref, session.provider_account_ref, value(account, :account_ref)},
      {:material_account_ref, session.provider_account_ref, value(material, :account_ref)},
      {:credential_generation, session.credential_generation, value(account, :generation)},
      {:material_generation, session.credential_generation, value(material, :generation)},
      {:materialization_ref, session.materialization_ref, value(request, :materialization_ref)},
      {:material_ref, session.materialization_ref, value(material, :materialization_ref)},
      {:credential_lease_ref, binding.credential_lease_ref, value(request, :lease_id)},
      {:authority_ref, binding.authority_ref || binding.authority_decision_ref,
       session.authority_ref},
      {:request_authority_ref, session.authority_ref, value(request, :authority_ref)},
      {:target_ref, binding.target_ref, session.target_ref},
      {:request_target_ref, session.target_ref, value(request, :target_ref)},
      {:fence, session.fence, value(account, :fence)},
      {:request_endpoint_ref, value(account, :endpoint_ref), value(request, :endpoint_ref)}
    ]

    required_refs = [
      session.session_ref,
      session.provider_account_ref,
      session.materialization_ref,
      session.authority_ref,
      session.target_ref,
      session.runtime_gateway,
      value(request, :lease_id),
      value(request, :effect_ref),
      value(request, :operation_ref),
      value(request, :endpoint_ref)
    ]

    cond do
      runtime_auth.provider_account_identity.identity_status not in [:known, :asserted] ->
        {:error,
         managed_error(
           :provider_account_unavailable,
           "managed session requires a current asserted provider account identity",
           %{status: runtime_auth.provider_account_identity.identity_status},
           provider
         )}

      not Enum.all?(required_refs, &safe_ref?/1) ->
        {:error,
         managed_error(
           :unsafe_identity,
           "managed session identity must use non-path opaque references",
           %{},
           provider
         )}

      not positive_integer?(session.credential_generation) or
          not non_negative_integer?(session.fence) ->
        {:error,
         managed_error(
           :invalid_generation,
           "managed session generation and fence are invalid",
           %{},
           provider
         )}

      mismatch = Enum.find(checks, &mismatch?/1) ->
        {field, _expected, _actual} = mismatch

        {:error,
         managed_error(
           :identity_mismatch,
           "managed session materialization does not match pinned authority",
           %{field: field},
           provider
         )}

      true ->
        :ok
    end
  end

  defp validate_time_window(request, provider) do
    issued_at = value(request, :issued_at)
    expires_at = value(request, :expires_at)
    now = DateTime.utc_now()

    cond do
      not is_struct(issued_at, DateTime) or not is_struct(expires_at, DateTime) ->
        {:error,
         managed_error(
           :invalid_expiry,
           "managed materialization requires issued_at and expires_at",
           %{},
           provider
         )}

      DateTime.compare(expires_at, issued_at) != :gt ->
        {:error,
         managed_error(
           :invalid_expiry,
           "managed materialization expiry is invalid",
           %{},
           provider
         )}

      DateTime.compare(issued_at, now) == :gt ->
        {:error,
         managed_error(
           :not_yet_valid,
           "managed materialization is not yet valid",
           %{issued_at: issued_at},
           provider
         )}

      DateTime.compare(expires_at, now) != :gt ->
        {:error,
         managed_error(
           :expired,
           "managed materialization has expired",
           %{expires_at: expires_at},
           provider
         )}

      true ->
        :ok
    end
  end

  defp workspace_root(opts, material, provider) do
    configured =
      Keyword.get(opts, :workspace_root) ||
        opts
        |> Keyword.get(:execution_environment)
        |> value(:workspace_root)

    payload = value(material, :payload, %{})
    materialized = value(payload, :workspace_root) || value(payload, :cwd)

    with {:ok, configured} <- normalize_absolute_path(configured),
         {:ok, materialized} <- normalize_absolute_path(materialized),
         true <- configured == materialized do
      {:ok, configured}
    else
      false ->
        {:error,
         managed_error(
           :workspace_mismatch,
           "managed materialization workspace does not match the pinned execution workspace",
           %{},
           provider
         )}

      :error ->
        {:error,
         managed_error(
           :workspace_required,
           "managed session requires an exact absolute workspace in execution and materialization",
           %{},
           provider
         )}
    end
  end

  defp workspace_ref(opts, workspace_root, provider) do
    ref =
      Keyword.get(opts, :workspace_ref) || Keyword.get(opts, :working_directory_ref) ||
        "workspace://sha256/#{workspace_digest(workspace_root)}"

    if safe_ref?(ref) do
      {:ok, ref}
    else
      {:error,
       managed_error(
         :workspace_ref_invalid,
         "managed session workspace_ref must be an opaque reference",
         %{},
         provider
       )}
    end
  end

  defp runtime_gateway_module(opts, provider) do
    case Keyword.get(opts, :runtime_gateway_module) do
      nil ->
        {:ok, nil}

      module when is_atom(module) ->
        if Code.ensure_loaded?(module) and
             Enum.all?(@gateway_callbacks, fn {name, arity} ->
               function_exported?(module, name, arity)
             end) do
          {:ok, module}
        else
          {:error,
           managed_error(
             :runtime_gateway_invalid,
             "managed session runtime gateway does not implement the frozen lifecycle",
             %{},
             provider
           )}
        end

      _other ->
        {:error,
         managed_error(
           :runtime_gateway_invalid,
           "managed session runtime gateway must be a module",
           %{},
           provider
         )}
    end
  end

  defp validate_runtime_gateway_ref(opts, session, provider) do
    case Keyword.get(opts, :runtime_gateway_ref) do
      nil ->
        :ok

      ref when ref == session.runtime_gateway ->
        :ok

      _other ->
        {:error,
         managed_error(
           :runtime_gateway_mismatch,
           "managed session runtime gateway ref does not match its contract",
           %{},
           provider
         )}
    end
  end

  defp reject_identity_rebinding(binding, opts, provider) do
    expected = %{
      execution_context_ref: binding.execution_context_ref,
      connector_instance_ref: binding.connector_instance_ref,
      connector_binding_ref: binding.connector_binding_ref,
      provider_account_ref: binding.provider_account_ref,
      credential_generation: binding.credential_generation,
      materialization_ref: binding.materialization_ref,
      credential_lease_ref: binding.lease_ref,
      authority_ref: binding.authority_ref,
      target_ref: binding.target_ref,
      operation_policy_ref: binding.operation_policy_ref,
      native_auth_assertion_ref: binding.native_auth_assertion_ref,
      workspace_ref: binding.workspace_ref,
      runtime_gateway_ref: binding.runtime_gateway_ref
    }

    mismatch =
      Enum.find(expected, fn {key, expected_value} ->
        Keyword.has_key?(opts, key) and Keyword.get(opts, key) != expected_value
      end)

    case mismatch do
      nil ->
        validate_workspace_rebinding(binding, opts, provider)

      {field, _expected} ->
        {:error,
         managed_error(
           :identity_rebinding,
           "managed session cannot change pinned account, generation, authority, or materialization",
           %{field: field},
           provider
         )}
    end
  end

  defp validate_runtime_auth_binding(binding, runtime_auth) do
    connector_binding = runtime_auth.connector_binding

    checks = [
      {:asm_session_id, binding.asm_session_id, runtime_auth.execution_context.session_id},
      {:provider_family, binding.provider_family,
       Atom.to_string(runtime_auth.execution_context.provider)},
      {:execution_context_ref, binding.execution_context_ref, runtime_auth.execution_context.ref},
      {:connector_instance_ref, binding.connector_instance_ref,
       runtime_auth.connector_instance.ref},
      {:connector_binding_ref, binding.connector_binding_ref, connector_binding.ref},
      {:provider_account_ref, binding.provider_account_ref,
       runtime_auth.provider_account_identity.ref},
      {:credential_lease_ref, binding.lease_ref, connector_binding.credential_lease_ref},
      {:authority_ref, binding.authority_ref,
       connector_binding.authority_ref || connector_binding.authority_decision_ref},
      {:target_ref, binding.target_ref, connector_binding.target_ref},
      {:operation_policy_ref, binding.operation_policy_ref,
       connector_binding.operation_policy_ref},
      {:native_auth_assertion_ref, binding.native_auth_assertion_ref,
       connector_binding.native_auth_assertion_ref}
    ]

    case Enum.find(checks, &mismatch?/1) do
      nil ->
        :ok

      {field, _expected, _actual} ->
        {:error,
         managed_error(
           :runtime_binding_mismatch,
           "managed session binding does not match its ASM runtime authority",
           %{field: field},
           runtime_auth.execution_context.provider
         )}
    end
  end

  defp validate_workspace_rebinding(binding, opts, provider) do
    roots =
      [
        Keyword.get(opts, :workspace_root),
        opts |> Keyword.get(:execution_environment) |> value(:workspace_root)
      ]
      |> Enum.reject(&is_nil/1)

    if Enum.all?(roots, fn root ->
         case normalize_absolute_path(root) do
           {:ok, normalized} -> workspace_digest(normalized) == binding.workspace_digest
           :error -> false
         end
       end) do
      :ok
    else
      {:error,
       managed_error(
         :workspace_rebinding,
         "managed session cannot change its pinned workspace",
         %{},
         provider
       )}
    end
  end

  defp reject_managed_overrides(opts, provider) do
    visible_opts =
      opts
      |> Keyword.drop([
        :managed_session,
        :managed_binding,
        :materialization_request,
        :secret_material,
        :codex_materialized_runtime
      ])
      |> Map.new()

    rejected =
      @managed_override_keys
      |> Enum.filter(fn key ->
        case Map.fetch(visible_opts, key) do
          {:ok, value} -> present_override?(value)
          :error -> false
        end
      end)

    nested_paths = secret_paths(visible_opts)

    if rejected == [] and nested_paths == [] do
      :ok
    else
      {:error,
       managed_error(
         :managed_override,
         "managed session rejects ambient or caller-supplied credential and routing material",
         %{keys: rejected, forbidden_paths: nested_paths},
         provider
       )}
    end
  end

  defp provider_family(account), do: account |> value(:provider_family) |> normalize_family()
  defp normalize_family(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_family(value) when is_binary(value), do: value
  defp normalize_family(_value), do: nil

  defp normalize_absolute_path(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and Path.type(trimmed) == :absolute do
      {:ok, Path.expand(trimmed)}
    else
      :error
    end
  end

  defp normalize_absolute_path(_value), do: :error

  defp workspace_digest(path) do
    :crypto.hash(:sha256, path)
    |> Base.encode16(case: :lower)
  end

  defp mismatch?({_field, expected, actual}), do: expected != actual

  defp optional_mismatch?({_field, _expected, nil}), do: false
  defp optional_mismatch?(check), do: mismatch?(check)

  defp known_fields?(attrs, fields) do
    allowed = MapSet.new(Enum.flat_map(fields, &[&1, Atom.to_string(&1)]))
    Enum.all?(Map.keys(attrs), &MapSet.member?(allowed, &1))
  end

  defp unknown_fields(attrs, fields) do
    allowed = MapSet.new(Enum.flat_map(fields, &[&1, Atom.to_string(&1)]))
    Enum.reject(Map.keys(attrs), &MapSet.member?(allowed, &1))
  end

  defp contains_runtime_handle?(%DateTime{}), do: false

  defp contains_runtime_handle?(%_{} = value),
    do: value |> Map.from_struct() |> contains_runtime_handle?()

  defp contains_runtime_handle?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      is_pid(key) or is_port(key) or is_reference(key) or contains_runtime_handle?(nested)
    end)
  end

  defp contains_runtime_handle?(value) when is_list(value),
    do: Enum.any?(value, &contains_runtime_handle?/1)

  defp contains_runtime_handle?(value),
    do: is_pid(value) or is_port(value) or is_reference(value)

  defp secret_paths(value), do: secret_paths(value, [], []) |> Enum.reverse()

  defp secret_paths(%DateTime{}, _path, acc), do: acc

  defp secret_paths(%_{} = value, path, acc),
    do: value |> Map.from_struct() |> secret_paths(path, acc)

  defp secret_paths(value, path, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {key, nested}, nested_acc ->
      normalized = key |> to_string() |> String.downcase()
      next_path = path ++ [normalized]

      nested_acc =
        if secret_key?(normalized), do: [Enum.join(next_path, ".") | nested_acc], else: nested_acc

      secret_paths(nested, next_path, nested_acc)
    end)
  end

  defp secret_paths(value, path, acc) when is_list(value) do
    Enum.reduce(value, acc, &secret_paths(&1, path, &2))
  end

  defp secret_paths(_value, _path, acc), do: acc

  defp secret_key?(key) do
    key in @secret_key_fragments or String.starts_with?(key, "raw_")
  end

  defp attrs(nil), do: nil
  defp attrs(%_{} = value), do: Map.from_struct(value)

  defp attrs(value) when is_list(value),
    do: if(Keyword.keyword?(value), do: Map.new(value), else: nil)

  defp attrs(value) when is_map(value), do: value
  defp attrs(_value), do: nil

  defp value(value, key, default \\ nil)

  defp value(nil, _key, default), do: default

  defp value(%_{} = value, key, default), do: value |> Map.from_struct() |> value(key, default)

  defp value(value, key, default) when is_map(value) do
    Map.get(value, key, Map.get(value, Atom.to_string(key), default))
  end

  defp value(_value, _key, default), do: default

  defp safe_ref?(value) when is_binary(value) do
    trimmed = String.trim(value)

    trimmed != "" and not String.starts_with?(trimmed, ["/", "~/"]) and
      not String.match?(trimmed, ~r/\A[A-Za-z]:[\\\/]/)
  end

  defp safe_ref?(_value), do: false
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp present_override?(nil), do: false
  defp present_override?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_override?(value) when is_list(value), do: value != []
  defp present_override?(value) when is_map(value), do: map_size(value) > 0
  defp present_override?(_value), do: true

  defp managed_error(reason, message, cause, provider \\ nil) do
    Error.new(:config_invalid, :config, message,
      provider: provider,
      cause: Map.put(cause, :reason, reason)
    )
  end
end
