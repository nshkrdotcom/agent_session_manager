defmodule ASM.RuntimeAuth do
  @moduledoc """
  ASM-local runtime-auth context for standalone provider execution.

  This module is intentionally owner-local to ASM. It records standalone
  execution context and connector evidence, but it does not issue durable
  credential leases or assert governed authority.
  """

  alias ASM.Error

  alias __MODULE__.{
    ConnectorBinding,
    ConnectorInstance,
    ExecutionContext,
    ProviderAccountIdentity
  }

  @modes [:standalone, :governed]
  @option_keys [
    :runtime_auth,
    :runtime_auth_mode,
    :runtime_auth_scope,
    :execution_context_ref,
    :connector_instance_ref,
    :connector_binding_ref,
    :connector_id,
    :connector_runtime_ref,
    :connector_auth_backend,
    :provider_auth_backend,
    :provider_account_ref,
    :provider_account_identity,
    :provider_account_evidence,
    :provider_account_status,
    :target_ref,
    :tenant_ref,
    :installation_ref,
    :authority_ref,
    :authority_decision_ref,
    :credential_lease_ref,
    :native_auth_assertion_ref
  ]

  @enforce_keys [
    :mode,
    :execution_context,
    :connector_instance,
    :connector_binding,
    :provider_account_identity,
    :provider_auth_backend
  ]
  defstruct [
    :mode,
    :execution_context,
    :connector_instance,
    :connector_binding,
    :provider_account_identity,
    :provider_auth_backend,
    connector_invocation_evidence: %{}
  ]

  @type mode :: :standalone | :governed
  @type t :: %__MODULE__{
          mode: mode(),
          execution_context: ExecutionContext.t(),
          connector_instance: ConnectorInstance.t(),
          connector_binding: ConnectorBinding.t(),
          provider_account_identity: ProviderAccountIdentity.t(),
          provider_auth_backend: atom(),
          connector_invocation_evidence: map()
        }

  defmodule ExecutionContext do
    @moduledoc """
    Runtime invocation context owned by ASM standalone execution.
    """

    @enforce_keys [:ref, :mode, :scope, :authority, :provider, :session_id]
    defstruct [
      :ref,
      :mode,
      :scope,
      :authority,
      :provider,
      :session_id,
      :tenant_ref,
      :installation_ref,
      :authority_ref,
      :authority_decision_ref,
      source: :asm_standalone
    ]

    @type t :: %__MODULE__{
            ref: String.t(),
            mode: ASM.RuntimeAuth.mode(),
            scope: atom(),
            authority: atom(),
            provider: atom(),
            session_id: String.t(),
            tenant_ref: String.t() | nil,
            installation_ref: String.t() | nil,
            authority_ref: String.t() | nil,
            authority_decision_ref: String.t() | nil,
            source: atom()
          }
  end

  defmodule ConnectorInstance do
    @moduledoc """
    Concrete standalone connector identity selected for a provider call.
    """

    @enforce_keys [:ref, :provider, :auth_backend]
    defstruct [
      :ref,
      :provider,
      :auth_backend,
      :runtime_ref,
      :connector_id,
      evidence: %{}
    ]

    @type t :: %__MODULE__{
            ref: String.t(),
            provider: atom(),
            auth_backend: atom(),
            runtime_ref: String.t() | nil,
            connector_id: String.t() | nil,
            evidence: map()
          }
  end

  defmodule ConnectorBinding do
    @moduledoc """
    Per-run connector binding evidence consumed by ASM run metadata.
    """

    @enforce_keys [:ref, :mode, :provider, :execution_context_ref, :connector_instance_ref]
    defstruct [
      :ref,
      :mode,
      :provider,
      :run_id,
      :execution_context_ref,
      :connector_instance_ref,
      :provider_account_ref,
      :target_ref,
      :authority_ref,
      :authority_decision_ref,
      :credential_lease_ref,
      :native_auth_assertion_ref
    ]

    @type t :: %__MODULE__{
            ref: String.t(),
            mode: ASM.RuntimeAuth.mode(),
            provider: atom(),
            run_id: String.t() | nil,
            execution_context_ref: String.t(),
            connector_instance_ref: String.t(),
            provider_account_ref: String.t() | nil,
            target_ref: String.t() | nil,
            authority_ref: String.t() | nil,
            authority_decision_ref: String.t() | nil,
            credential_lease_ref: String.t() | nil,
            native_auth_assertion_ref: String.t() | nil
          }
  end

  defmodule ProviderAccountIdentity do
    @moduledoc """
    Redacted provider account evidence, distinct from connector identity.
    """

    @enforce_keys [:ref, :provider, :identity_status]
    defstruct [
      :ref,
      :provider,
      :identity_status,
      redacted?: true,
      evidence: %{}
    ]

    @type t :: %__MODULE__{
            ref: String.t(),
            provider: atom(),
            identity_status: atom(),
            redacted?: boolean(),
            evidence: map()
          }
  end

  @spec option_keys() :: [atom()]
  def option_keys, do: @option_keys

  @spec new(String.t(), atom(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(session_id, provider, opts \\ [])
      when is_binary(session_id) and is_atom(provider) and is_list(opts) do
    case Keyword.get(opts, :runtime_auth) do
      nil ->
        build(session_id, provider, nil, opts)

      %__MODULE__{} = runtime_auth ->
        validate(runtime_auth)

      other ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "runtime_auth must be an %ASM.RuntimeAuth{} when provided",
           cause: other,
           provider: provider
         )}
    end
  end

  @spec new!(String.t(), atom(), keyword()) :: t()
  def new!(session_id, provider, opts \\ []) do
    case new(session_id, provider, opts) do
      {:ok, runtime_auth} -> runtime_auth
      {:error, %Error{} = error} -> raise error
    end
  end

  @spec for_run(t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def for_run(%__MODULE__{} = runtime_auth, run_id, opts \\ [])
      when is_binary(run_id) and is_list(opts) do
    provider = runtime_auth.execution_context.provider
    session_id = runtime_auth.execution_context.session_id

    base_opts =
      [
        runtime_auth_mode: runtime_auth.mode,
        runtime_auth_scope: runtime_auth.execution_context.scope,
        execution_context_ref: runtime_auth.execution_context.ref,
        connector_instance_ref: runtime_auth.connector_instance.ref,
        connector_binding_ref: runtime_auth.connector_binding.ref,
        connector_id: runtime_auth.connector_instance.connector_id,
        connector_runtime_ref: runtime_auth.connector_instance.runtime_ref,
        connector_auth_backend: runtime_auth.connector_instance.auth_backend,
        provider_auth_backend: runtime_auth.provider_auth_backend,
        provider_account_ref: runtime_auth.provider_account_identity.ref,
        provider_account_status: runtime_auth.provider_account_identity.identity_status,
        provider_account_evidence: runtime_auth.provider_account_identity.evidence,
        target_ref: runtime_auth.connector_binding.target_ref,
        tenant_ref: runtime_auth.execution_context.tenant_ref,
        installation_ref: runtime_auth.execution_context.installation_ref,
        authority_ref: runtime_auth.connector_binding.authority_ref,
        authority_decision_ref: runtime_auth.connector_binding.authority_decision_ref,
        credential_lease_ref: runtime_auth.connector_binding.credential_lease_ref,
        native_auth_assertion_ref: runtime_auth.connector_binding.native_auth_assertion_ref
      ]
      |> Keyword.merge(opts)
      |> Keyword.delete(:runtime_auth)

    build(session_id, provider, run_id, base_opts)
  end

  @spec to_metadata(t()) :: map()
  def to_metadata(%__MODULE__{} = runtime_auth) do
    runtime_auth_map = to_map(runtime_auth)

    %{
      runtime_auth: runtime_auth_map,
      runtime_auth_mode: runtime_auth.mode,
      execution_context: runtime_auth_map.execution_context,
      execution_context_ref: runtime_auth.execution_context.ref,
      connector_instance: runtime_auth_map.connector_instance,
      connector_instance_ref: runtime_auth.connector_instance.ref,
      connector_binding: runtime_auth_map.connector_binding,
      connector_binding_ref: runtime_auth.connector_binding.ref,
      provider_account_identity: runtime_auth_map.provider_account_identity,
      provider_account_ref: runtime_auth.provider_account_identity.ref,
      provider_auth_backend: runtime_auth.provider_auth_backend,
      connector_invocation_evidence: runtime_auth.connector_invocation_evidence,
      governed_authority: governed_authority?(runtime_auth)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = runtime_auth) do
    %{
      mode: runtime_auth.mode,
      execution_context: struct_to_map(runtime_auth.execution_context),
      connector_instance: struct_to_map(runtime_auth.connector_instance),
      connector_binding: struct_to_map(runtime_auth.connector_binding),
      provider_account_identity: struct_to_map(runtime_auth.provider_account_identity),
      provider_auth_backend: runtime_auth.provider_auth_backend,
      connector_invocation_evidence: runtime_auth.connector_invocation_evidence
    }
  end

  @spec governed_authority?(t() | map() | term()) :: boolean()
  def governed_authority?(%__MODULE__{} = runtime_auth) do
    context = runtime_auth.execution_context
    binding = runtime_auth.connector_binding

    governed_mode?(runtime_auth.mode) and governed_scope?(context.scope) and
      present?(binding.authority_ref || binding.authority_decision_ref)
  end

  def governed_authority?(metadata) when is_map(metadata) do
    runtime_auth = map_value(metadata, :runtime_auth)

    context =
      map_value(metadata, :execution_context) || map_value(runtime_auth, :execution_context)

    binding =
      map_value(metadata, :connector_binding) || map_value(runtime_auth, :connector_binding)

    mode = map_value(metadata, :runtime_auth_mode) || map_value(runtime_auth, :mode)
    scope = map_value(context, :scope)
    authority_ref = map_value(metadata, :authority_ref) || map_value(binding, :authority_ref)

    authority_decision_ref =
      map_value(metadata, :authority_decision_ref) || map_value(binding, :authority_decision_ref)

    governed_mode?(mode) and governed_scope?(scope) and
      present?(authority_ref || authority_decision_ref)
  end

  def governed_authority?(_other), do: false

  defp build(session_id, provider, run_id, opts) do
    with {:ok, mode} <-
           normalize_mode(Keyword.get(opts, :runtime_auth_mode, :standalone), provider),
         {:ok, provider_auth_backend} <-
           normalize_backend(Keyword.get(opts, :provider_auth_backend)),
         {:ok, connector_auth_backend} <-
           normalize_backend(Keyword.get(opts, :connector_auth_backend, provider_auth_backend)) do
      context = execution_context(session_id, provider, mode, opts)
      connector = connector_instance(provider, connector_auth_backend, opts)
      account = provider_account_identity(provider, opts)
      binding = connector_binding(provider, run_id, mode, context, connector, account, opts)

      runtime_auth = %__MODULE__{
        mode: mode,
        execution_context: context,
        connector_instance: connector,
        connector_binding: binding,
        provider_account_identity: account,
        provider_auth_backend: provider_auth_backend,
        connector_invocation_evidence:
          connector_invocation_evidence(provider, run_id, context, connector, account, binding)
      }

      validate(runtime_auth)
    end
  end

  defp execution_context(session_id, provider, mode, opts) do
    %ExecutionContext{
      ref:
        string_option(
          opts,
          :execution_context_ref,
          "asm-execution-context://#{mode}/#{safe_ref_part(session_id)}"
        ),
      mode: mode,
      scope: Keyword.get(opts, :runtime_auth_scope, mode),
      authority: context_authority(mode),
      provider: provider,
      session_id: session_id,
      tenant_ref: optional_string(opts, :tenant_ref),
      installation_ref: optional_string(opts, :installation_ref),
      authority_ref: optional_string(opts, :authority_ref),
      authority_decision_ref: optional_string(opts, :authority_decision_ref),
      source: context_source(mode)
    }
  end

  defp connector_instance(provider, auth_backend, opts) do
    connector_id = optional_string(opts, :connector_id) || "default"
    runtime_ref = optional_string(opts, :connector_runtime_ref)

    %ConnectorInstance{
      ref:
        string_option(
          opts,
          :connector_instance_ref,
          "asm-connector-instance://standalone/#{provider}/#{safe_ref_part(connector_id)}"
        ),
      provider: provider,
      auth_backend: auth_backend,
      runtime_ref: runtime_ref,
      connector_id: connector_id,
      evidence: %{
        owner: :asm,
        identity_kind: :connector_instance,
        runtime_ref: runtime_ref
      }
    }
  end

  defp provider_account_identity(provider, opts) do
    evidence =
      case Keyword.get(opts, :provider_account_evidence) do
        evidence when is_map(evidence) -> evidence
        _other -> %{introspection: :not_attempted}
      end

    %ProviderAccountIdentity{
      ref:
        string_option(
          opts,
          :provider_account_ref,
          "provider-account://#{provider}/unknown"
        ),
      provider: provider,
      identity_status: Keyword.get(opts, :provider_account_status, :unknown),
      redacted?: true,
      evidence: Map.put_new(evidence, :redacted, true)
    }
  end

  defp connector_binding(provider, run_id, mode, context, connector, account, opts) do
    default_ref = "asm-connector-binding://#{mode}/#{safe_ref_part(context.session_id)}"

    %ConnectorBinding{
      ref: string_option(opts, :connector_binding_ref, default_ref),
      mode: mode,
      provider: provider,
      run_id: run_id,
      execution_context_ref: context.ref,
      connector_instance_ref: connector.ref,
      provider_account_ref: account.ref,
      target_ref: optional_string(opts, :target_ref),
      authority_ref: optional_string(opts, :authority_ref),
      authority_decision_ref: optional_string(opts, :authority_decision_ref),
      credential_lease_ref: optional_string(opts, :credential_lease_ref),
      native_auth_assertion_ref: optional_string(opts, :native_auth_assertion_ref)
    }
  end

  defp connector_invocation_evidence(provider, run_id, context, connector, account, binding) do
    %{
      evidence_type: :connector_invocation,
      provider: provider,
      run_id: run_id,
      mode: binding.mode,
      execution_context_ref: context.ref,
      connector_instance_ref: connector.ref,
      connector_binding_ref: binding.ref,
      provider_account_ref: account.ref,
      governed_authority: false
    }
  end

  defp validate(%__MODULE__{} = runtime_auth) do
    if runtime_auth.connector_instance.ref == runtime_auth.provider_account_identity.ref do
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "connector_instance_ref must be distinct from provider_account_ref",
         provider: runtime_auth.execution_context.provider,
         cause: %{
           connector_instance_ref: runtime_auth.connector_instance.ref,
           provider_account_ref: runtime_auth.provider_account_identity.ref
         }
       )}
    else
      {:ok, runtime_auth}
    end
  end

  defp normalize_mode(mode, _provider) when mode in @modes, do: {:ok, mode}

  defp normalize_mode(mode, provider) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "runtime_auth_mode must be :standalone or :governed",
       cause: mode,
       provider: provider
     )}
  end

  defp normalize_backend(nil), do: {:ok, :standalone_native}
  defp normalize_backend(backend) when is_atom(backend), do: {:ok, backend}

  defp normalize_backend(backend) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "provider_auth_backend and connector_auth_backend must be atoms",
       cause: backend
     )}
  end

  defp context_authority(:standalone), do: :local_only
  defp context_authority(:governed), do: :external_authority

  defp context_source(:standalone), do: :asm_standalone
  defp context_source(:governed), do: :governed_context

  defp string_option(opts, key, default) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      nil -> default
      _other -> default
    end
  end

  defp optional_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp safe_ref_part(value) when is_atom(value), do: value |> Atom.to_string() |> safe_ref_part()

  defp safe_ref_part(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> Enum.map(fn
      char when char in ?a..?z -> char
      char when char in ?A..?Z -> char
      char when char in ?0..?9 -> char
      char when char in [?_, ?., ?-] -> char
      _char -> ?_
    end)
    |> IO.iodata_to_binary()
    |> case do
      "" -> "default"
      ref_part -> ref_part
    end
  end

  defp safe_ref_part(_value), do: "default"

  defp struct_to_map(struct) when is_map(struct) do
    struct
    |> Map.from_struct()
    |> Enum.into(%{}, fn {key, value} -> {key, value} end)
  end

  defp map_value(nil, _key), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp governed_mode?(mode), do: mode in [:governed, "governed"]
  defp governed_scope?(scope), do: scope in [:governed, "governed"]

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value)
end
