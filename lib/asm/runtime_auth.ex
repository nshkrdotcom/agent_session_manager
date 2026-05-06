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
  @provider_account_statuses [:known, :asserted, :unknown, :unavailable, :revoked, :rotated]
  @provider_auth_env_keys %{
    codex: [
      "CODEX_API_KEY",
      "CODEX_HOME",
      "CODEX_MODEL",
      "CODEX_MODEL_DEFAULT",
      "CODEX_OLLAMA_BASE_URL",
      "CODEX_OPENAI_BASE_URL",
      "CODEX_OSS_PROVIDER",
      "CODEX_PATH",
      "CODEX_PROVIDER_BACKEND",
      "OPENAI_API_KEY",
      "OPENAI_BASE_URL",
      "OPENAI_DEFAULT_MODEL"
    ],
    claude: [
      "ANTHROPIC_API_KEY",
      "ANTHROPIC_AUTH_TOKEN",
      "ANTHROPIC_BASE_URL",
      "ASM_CLAUDE_MODEL",
      "CLAUDE_CLI_PATH",
      "CLAUDE_CODE_OAUTH_TOKEN",
      "CLAUDE_CONFIG_DIR",
      "CLAUDE_HOME",
      "CLAUDE_MODEL"
    ],
    gemini: [
      "ASM_GEMINI_MODEL",
      "GEMINI_API_KEY",
      "GEMINI_CLI_CONFIG_HOME",
      "GEMINI_CLI_PATH",
      "GEMINI_MODEL",
      "GOOGLE_API_KEY",
      "GOOGLE_APPLICATION_CREDENTIALS"
    ],
    amp: [
      "AMP_API_KEY",
      "AMP_AUTH_TOKEN",
      "AMP_BASE_URL",
      "AMP_CLI_PATH",
      "AMP_HOME",
      "AMP_MODEL",
      "ASM_AMP_MODEL"
    ]
  }
  @governed_provider_override_keys [
    :access_token,
    :api_key,
    :auth_root,
    :auth_token,
    :authorization_header,
    :base_url,
    :cli_path,
    :cmd,
    :command,
    :config_root,
    :continue_conversation,
    :continue_thread,
    :cwd,
    :env,
    :headers,
    :oauth_token,
    :path_to_claude_code_executable,
    :pat,
    :process_env,
    :provider_session_id,
    :refresh_token,
    :resume,
    :token,
    :token_file,
    :working_directory,
    :anthropic_auth_token,
    :anthropic_base_url,
    :default_client,
    :singleton_client
  ]
  @provider_account_evidence_forbidden_keys [
    :api_key,
    :auth_json,
    :authorization_header,
    :native_auth_file,
    :provider_payload,
    :raw_secret,
    :raw_token,
    :refresh_token,
    :target_credentials,
    :token,
    :token_file
  ]
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
    :operation_policy_ref,
    :tenant_ref,
    :installation_ref,
    :authority_ref,
    :authority_decision_ref,
    :credential_handle_ref,
    :credential_lease_ref,
    :native_auth_assertion_ref,
    :prompt_ref,
    :guard_chain_ref,
    :replay_mode
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
      :operation_policy_ref,
      :authority_ref,
      :authority_decision_ref,
      :credential_handle_ref,
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
            operation_policy_ref: String.t() | nil,
            authority_ref: String.t() | nil,
            authority_decision_ref: String.t() | nil,
            credential_handle_ref: String.t() | nil,
            credential_lease_ref: String.t() | nil,
            native_auth_assertion_ref: String.t() | nil
          }
  end

  defmodule HandoffPacket do
    @moduledoc """
    Ref-only ASM handoff packet for governed session transfer.

    The packet is intentionally a value contract. It carries refs that a
    receiving agent must revalidate before materialization and never carries
    provider payloads, raw tokens, local auth roots, command env, or target
    credentials.
    """

    @enforce_keys [
      :handoff_ref,
      :provider,
      :runtime_auth_mode,
      :tenant_ref,
      :installation_ref,
      :execution_context_ref,
      :connector_instance_ref,
      :connector_binding_ref,
      :provider_account_ref,
      :credential_handle_ref,
      :credential_lease_ref,
      :native_auth_assertion_ref,
      :target_ref,
      :operation_policy_ref,
      :trace_ref,
      :idempotency_key,
      :prompt_ref,
      :guard_chain_ref
    ]
    defstruct [
      :handoff_ref,
      :provider,
      :runtime_auth_mode,
      :tenant_ref,
      :installation_ref,
      :execution_context_ref,
      :connector_instance_ref,
      :connector_binding_ref,
      :provider_account_ref,
      :provider_account_status,
      :credential_handle_ref,
      :credential_lease_ref,
      :native_auth_assertion_ref,
      :target_ref,
      :operation_policy_ref,
      :authority_ref,
      :authority_decision_ref,
      :trace_ref,
      :idempotency_key,
      :prompt_ref,
      :guard_chain_ref,
      :replay_mode,
      :memory_scope_refs,
      :context_budget_refs,
      redacted?: true
    ]

    @type t :: %__MODULE__{
            handoff_ref: String.t(),
            provider: atom(),
            runtime_auth_mode: ASM.RuntimeAuth.mode(),
            tenant_ref: String.t(),
            installation_ref: String.t(),
            execution_context_ref: String.t(),
            connector_instance_ref: String.t(),
            connector_binding_ref: String.t(),
            provider_account_ref: String.t(),
            provider_account_status: atom() | nil,
            credential_handle_ref: String.t(),
            credential_lease_ref: String.t(),
            native_auth_assertion_ref: String.t(),
            target_ref: String.t(),
            operation_policy_ref: String.t(),
            authority_ref: String.t() | nil,
            authority_decision_ref: String.t() | nil,
            trace_ref: String.t(),
            idempotency_key: String.t(),
            prompt_ref: String.t(),
            guard_chain_ref: String.t(),
            replay_mode: atom() | nil,
            memory_scope_refs: [String.t()],
            context_budget_refs: [String.t()],
            redacted?: true
          }
  end

  @handoff_required_refs [
    :handoff_ref,
    :tenant_ref,
    :installation_ref,
    :execution_context_ref,
    :connector_instance_ref,
    :connector_binding_ref,
    :provider_account_ref,
    :credential_handle_ref,
    :credential_lease_ref,
    :native_auth_assertion_ref,
    :target_ref,
    :operation_policy_ref,
    :trace_ref,
    :idempotency_key,
    :prompt_ref,
    :guard_chain_ref
  ]

  @handoff_context_refs [
    :replay_mode,
    :memory_scope_refs,
    :context_budget_refs
  ]

  @replay_modes [
    :exact,
    :prompt_variant,
    :model_variant,
    :policy_variant,
    :guard_variant,
    :memory_variant
  ]

  @handoff_forbidden_keys [
    :access_token,
    :api_key,
    :auth_root,
    :auth_token,
    :authorization_header,
    :command,
    :config_root,
    :cwd,
    :env,
    :headers,
    :oauth_token,
    :provider_payload,
    :raw_secret,
    :raw_token,
    :target_credentials,
    :token,
    :token_file
  ]

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

  @spec provider_account_statuses() :: [atom()]
  def provider_account_statuses, do: @provider_account_statuses

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

    with :ok <- reject_standalone_governed_upgrade(runtime_auth, opts) do
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
          operation_policy_ref: runtime_auth.connector_binding.operation_policy_ref,
          tenant_ref: runtime_auth.execution_context.tenant_ref,
          installation_ref: runtime_auth.execution_context.installation_ref,
          authority_ref: runtime_auth.connector_binding.authority_ref,
          authority_decision_ref: runtime_auth.connector_binding.authority_decision_ref,
          credential_handle_ref: runtime_auth.connector_binding.credential_handle_ref,
          credential_lease_ref: runtime_auth.connector_binding.credential_lease_ref,
          native_auth_assertion_ref: runtime_auth.connector_binding.native_auth_assertion_ref
        ]
        |> Keyword.merge(opts)
        |> Keyword.delete(:runtime_auth)

      build(session_id, provider, run_id, base_opts)
    end
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
      target_ref: runtime_auth.connector_binding.target_ref,
      operation_policy_ref: runtime_auth.connector_binding.operation_policy_ref,
      credential_handle_ref: runtime_auth.connector_binding.credential_handle_ref,
      credential_lease_ref: runtime_auth.connector_binding.credential_lease_ref,
      native_auth_assertion_ref: runtime_auth.connector_binding.native_auth_assertion_ref,
      authority_ref: runtime_auth.connector_binding.authority_ref,
      authority_decision_ref: runtime_auth.connector_binding.authority_decision_ref,
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

  @spec handoff_packet(t(), keyword()) :: {:ok, HandoffPacket.t()} | {:error, Error.t()}
  def handoff_packet(%__MODULE__{} = runtime_auth, opts \\ []) when is_list(opts) do
    attrs = %{
      handoff_ref:
        string_option(
          opts,
          :handoff_ref,
          "asm-handoff://#{safe_ref_part(runtime_auth.execution_context.session_id)}"
        ),
      provider: runtime_auth.execution_context.provider,
      runtime_auth_mode: runtime_auth.mode,
      tenant_ref: runtime_auth.execution_context.tenant_ref || optional_string(opts, :tenant_ref),
      installation_ref:
        runtime_auth.execution_context.installation_ref ||
          optional_string(opts, :installation_ref),
      execution_context_ref: runtime_auth.execution_context.ref,
      connector_instance_ref: runtime_auth.connector_instance.ref,
      connector_binding_ref: runtime_auth.connector_binding.ref,
      provider_account_ref: runtime_auth.provider_account_identity.ref,
      provider_account_status: runtime_auth.provider_account_identity.identity_status,
      credential_handle_ref:
        runtime_auth.connector_binding.credential_handle_ref ||
          optional_string(opts, :credential_handle_ref),
      credential_lease_ref: runtime_auth.connector_binding.credential_lease_ref,
      native_auth_assertion_ref: runtime_auth.connector_binding.native_auth_assertion_ref,
      target_ref: runtime_auth.connector_binding.target_ref,
      operation_policy_ref: runtime_auth.connector_binding.operation_policy_ref,
      authority_ref: runtime_auth.connector_binding.authority_ref,
      authority_decision_ref: runtime_auth.connector_binding.authority_decision_ref,
      trace_ref: optional_string(opts, :trace_ref),
      idempotency_key: optional_string(opts, :idempotency_key),
      prompt_ref: optional_string(opts, :prompt_ref),
      guard_chain_ref: optional_string(opts, :guard_chain_ref),
      replay_mode: replay_mode_option(opts),
      memory_scope_refs: ref_list_option(opts, :memory_scope_refs),
      context_budget_refs: ref_list_option(opts, :context_budget_refs)
    }

    missing = missing_handoff_refs(attrs)

    cond do
      runtime_auth.provider_account_identity.identity_status in [:revoked, :rotated, :unavailable] ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "ASM handoff rejects revoked, rotated, or unavailable provider account authority",
           provider: runtime_auth.execution_context.provider,
           cause: %{
             provider_account_ref: runtime_auth.provider_account_identity.ref,
             provider_account_status: runtime_auth.provider_account_identity.identity_status
           }
         )}

      missing != [] ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "ASM handoff requires tenant, installation, connector, provider account, credential, target, operation, trace, and idempotency refs",
           provider: runtime_auth.execution_context.provider,
           cause: %{missing_refs: missing}
         )}

      invalid_replay_mode?(attrs) ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "ASM handoff replay_mode must use a bounded replay class",
           provider: runtime_auth.execution_context.provider,
           cause: %{replay_mode: attrs.replay_mode}
         )}

      not governed_authority?(runtime_auth) ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "ASM governed handoff requires governed runtime authority before transfer",
           provider: runtime_auth.execution_context.provider,
           cause: governed_validation_cause(runtime_auth)
         )}

      true ->
        {:ok, struct!(HandoffPacket, attrs)}
    end
  end

  @spec accept_handoff(HandoffPacket.t() | map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def accept_handoff(packet, opts \\ []) when is_list(opts) do
    packet = normalize_handoff_packet(packet)
    forbidden = Enum.filter(@handoff_forbidden_keys, &Keyword.has_key?(opts, &1))
    missing = missing_handoff_refs(packet)
    mismatches = expected_handoff_mismatches(packet, opts)

    cond do
      forbidden != [] ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "ASM handoff accepts only refs and rejects raw provider, command, env, and target material",
           provider: Map.get(packet, :provider),
           cause: %{keys: forbidden}
         )}

      missing != [] ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "ASM handoff acceptance requires complete preserved refs",
           provider: Map.get(packet, :provider),
           cause: %{missing_refs: missing}
         )}

      Map.get(packet, :provider_account_status) in [:revoked, :rotated, :unavailable] ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "ASM handoff acceptance rejects revoked, rotated, or unavailable provider account authority",
           provider: Map.get(packet, :provider),
           cause: %{
             provider_account_ref: Map.get(packet, :provider_account_ref),
             provider_account_status: Map.get(packet, :provider_account_status)
           }
         )}

      mismatches != [] ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "ASM handoff acceptance rejects stale or mismatched preserved refs",
           provider: Map.get(packet, :provider),
           cause: %{mismatches: mismatches}
         )}

      invalid_replay_mode?(packet) ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "ASM handoff acceptance rejects unknown replay mode",
           provider: Map.get(packet, :provider),
           cause: %{replay_mode: Map.get(packet, :replay_mode)}
         )}

      true ->
        {:ok,
         packet
         |> Map.take(
           @handoff_required_refs ++
             [:authority_ref, :authority_decision_ref] ++
             @handoff_context_refs
         )
         |> Map.put(:handoff_status, :accepted)
         |> Map.put(:redacted?, true)}
    end
  end

  @spec governed_authority?(t() | map() | term()) :: boolean()
  def governed_authority?(%__MODULE__{} = runtime_auth) do
    context = runtime_auth.execution_context
    binding = runtime_auth.connector_binding

    governed_mode?(runtime_auth.mode) and governed_scope?(context.scope) and
      governed_source?(context.source) and governed_binding_evidence?(binding) and
      governed_identity_evidence?(runtime_auth)
  end

  def governed_authority?(metadata) when is_map(metadata) do
    runtime_auth = map_value(metadata, :runtime_auth)

    context =
      map_value(metadata, :execution_context) || map_value(runtime_auth, :execution_context)

    binding =
      map_value(metadata, :connector_binding) || map_value(runtime_auth, :connector_binding)

    metadata
    |> governed_map_authority_evidence(runtime_auth, context, binding)
    |> governed_authority_evidence?()
  end

  def governed_authority?(_other), do: false

  @spec governed_context?(t() | map() | term()) :: boolean()
  def governed_context?(%__MODULE__{} = runtime_auth) do
    governed_mode?(runtime_auth.mode) or governed_scope?(runtime_auth.execution_context.scope)
  end

  def governed_context?(metadata) when is_map(metadata) do
    runtime_auth = map_value(metadata, :runtime_auth)

    context =
      map_value(metadata, :execution_context) || map_value(runtime_auth, :execution_context)

    mode = map_value(metadata, :runtime_auth_mode) || map_value(runtime_auth, :mode)
    scope = map_value(metadata, :runtime_auth_scope) || map_value(context, :scope)

    governed_mode?(mode) or governed_scope?(scope)
  end

  def governed_context?(_other), do: false

  @spec authorize_governed_provider_runtime(atom(), map(), keyword()) ::
          :ok | {:error, Error.t()}
  def authorize_governed_provider_runtime(provider, config, provider_opts)
      when is_atom(provider) and is_map(config) and is_list(provider_opts) do
    metadata = Map.get(config, :metadata, %{})
    runtime_auth = Map.get(config, :runtime_auth, metadata)

    if governed_context?(runtime_auth) or governed_context?(metadata) do
      with :ok <- require_governed_runtime_authority(provider, runtime_auth, metadata),
           :ok <- reject_governed_provider_overrides(provider, provider_opts),
           :ok <- reject_governed_provider_env_values(provider, provider_opts),
           :ok <- reject_unmanaged_provider_env(provider) do
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "governed #{provider} runtime requires verified provider-auth materialization; standalone env, native login, and provider defaults cannot satisfy governed authority",
           provider: provider
         )}
      end
    else
      :ok
    end
  end

  defp governed_map_authority_evidence(metadata, runtime_auth, context, binding) do
    sources = [metadata, binding]

    %{
      mode: first_present_map_value([metadata, runtime_auth], :runtime_auth_mode, :mode),
      scope: map_value(context, :scope),
      source: map_value(context, :source),
      authority_ref: first_present_map_value(sources, :authority_ref),
      authority_decision_ref: first_present_map_value(sources, :authority_decision_ref),
      credential_handle_ref: first_present_map_value(sources, :credential_handle_ref),
      credential_lease_ref: first_present_map_value(sources, :credential_lease_ref),
      native_auth_assertion_ref: first_present_map_value(sources, :native_auth_assertion_ref),
      connector_instance_ref: first_present_map_value(sources, :connector_instance_ref),
      provider_account_ref: first_present_map_value(sources, :provider_account_ref),
      target_ref: first_present_map_value(sources, :target_ref),
      operation_policy_ref: first_present_map_value(sources, :operation_policy_ref)
    }
  end

  defp governed_authority_evidence?(evidence) do
    governed_authority_context?(evidence) and
      authority_decision_present?(evidence) and required_governed_refs_present?(evidence)
  end

  defp governed_authority_context?(evidence) do
    governed_mode?(evidence.mode) and governed_scope?(evidence.scope) and
      governed_source?(evidence.source)
  end

  defp authority_decision_present?(evidence) do
    present?(evidence.authority_ref) or present?(evidence.authority_decision_ref)
  end

  defp required_governed_refs_present?(evidence) do
    [
      :credential_lease_ref,
      :native_auth_assertion_ref,
      :connector_instance_ref,
      :provider_account_ref,
      :target_ref,
      :operation_policy_ref
    ]
    |> Enum.all?(&present?(Map.fetch!(evidence, &1)))
  end

  defp require_governed_runtime_authority(provider, runtime_auth, metadata) do
    if governed_authority?(runtime_auth) or governed_authority?(metadata) do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "governed #{provider} runtime requires authority ref, credential lease ref, native auth assertion ref, connector instance ref, provider account ref, target ref, and operation policy ref",
         provider: provider,
         cause: %{runtime_auth: runtime_auth, metadata: metadata}
       )}
    end
  end

  defp reject_governed_provider_overrides(provider, provider_opts) do
    rejected =
      @governed_provider_override_keys
      |> Enum.filter(&present_option?(provider_opts, &1))
      |> Enum.uniq()

    if rejected == [] do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "governed #{provider} runtime rejects provider auth, target, session, command, cwd, or env overrides outside the authority materializer",
         provider: provider,
         cause: %{keys: rejected}
       )}
    end
  end

  defp reject_governed_provider_env_values(provider, provider_opts) do
    env_keys =
      []
      |> collect_env_keys(Keyword.get(provider_opts, :env))
      |> collect_env_keys(Keyword.get(provider_opts, :process_env))
      |> collect_model_payload_env_keys(Keyword.get(provider_opts, :model_payload))
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 in provider_env_keys(provider)))
      |> Enum.uniq()

    if env_keys == [] do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "governed #{provider} runtime rejects provider auth env outside the authority materializer",
         provider: provider,
         cause: %{env_keys: env_keys}
       )}
    end
  end

  defp collect_env_keys(acc, nil), do: acc

  defp collect_env_keys(acc, env) when is_map(env), do: acc ++ Map.keys(env)

  defp collect_env_keys(acc, env) when is_list(env) do
    if Keyword.keyword?(env), do: acc ++ Keyword.keys(env), else: acc
  end

  defp collect_env_keys(acc, _env), do: acc

  defp collect_model_payload_env_keys(acc, nil), do: acc

  defp collect_model_payload_env_keys(acc, model_payload) when is_map(model_payload) do
    env_overrides =
      map_value(model_payload, :env_overrides) ||
        model_payload
        |> map_value(:backend_metadata)
        |> map_value(:env_overrides)

    collect_env_keys(acc, env_overrides)
  end

  defp collect_model_payload_env_keys(acc, _model_payload), do: acc

  defp reject_unmanaged_provider_env(provider) do
    unmanaged =
      provider
      |> provider_env_keys()
      |> Enum.filter(fn key ->
        case System.get_env(key) do
          nil -> false
          "" -> false
          _value -> true
        end
      end)

    if unmanaged == [] do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "governed #{provider} runtime rejects unmanaged ambient provider auth environment",
         provider: provider,
         cause: %{env_keys: unmanaged}
       )}
    end
  end

  defp provider_env_keys(provider), do: Map.get(@provider_auth_env_keys, provider, [])

  defp present_option?(opts, key) when is_list(opts) do
    case Keyword.get(opts, key) do
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      value when is_list(value) -> value != []
      value when is_map(value) -> map_size(value) > 0
      _value -> true
    end
  end

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
      identity_status:
        normalize_provider_account_status(Keyword.get(opts, :provider_account_status, :unknown)),
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
      operation_policy_ref: optional_string(opts, :operation_policy_ref),
      authority_ref: optional_string(opts, :authority_ref),
      authority_decision_ref: optional_string(opts, :authority_decision_ref),
      credential_handle_ref: optional_string(opts, :credential_handle_ref),
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
    cond do
      runtime_auth.connector_instance.ref == runtime_auth.provider_account_identity.ref ->
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

      runtime_auth.provider_account_identity.identity_status not in @provider_account_statuses ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "provider_account_status must be known, asserted, unknown, unavailable, revoked, or rotated",
           provider: runtime_auth.execution_context.provider,
           cause: %{
             provider_account_status: runtime_auth.provider_account_identity.identity_status,
             allowed_statuses: @provider_account_statuses
           }
         )}

      provider_account_evidence_forbidden_hits(runtime_auth.provider_account_identity.evidence) !=
          [] ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "provider_account_evidence must be redacted and cannot contain raw credential or provider payload fields",
           provider: runtime_auth.execution_context.provider,
           cause: %{
             keys:
               provider_account_evidence_forbidden_hits(
                 runtime_auth.provider_account_identity.evidence
               )
           }
         )}

      governed_context?(runtime_auth) and not governed_authority?(runtime_auth) ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "governed runtime_auth requires governed context source, authority ref, credential lease ref, native auth assertion ref, connector instance ref, provider account ref, target ref, and operation policy ref",
           provider: runtime_auth.execution_context.provider,
           cause: governed_validation_cause(runtime_auth)
         )}

      true ->
        {:ok, runtime_auth}
    end
  end

  defp reject_standalone_governed_upgrade(%__MODULE__{mode: :standalone} = runtime_auth, opts) do
    requested_mode = Keyword.get(opts, :runtime_auth_mode, runtime_auth.mode)
    requested_scope = Keyword.get(opts, :runtime_auth_scope, runtime_auth.execution_context.scope)

    if governed_mode?(requested_mode) or governed_scope?(requested_scope) do
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "standalone runtime_auth cannot be upgraded or relabeled as governed authority",
         provider: runtime_auth.execution_context.provider,
         cause: %{
           runtime_auth_mode: requested_mode,
           runtime_auth_scope: requested_scope,
           execution_context_ref: runtime_auth.execution_context.ref
         }
       )}
    else
      :ok
    end
  end

  defp reject_standalone_governed_upgrade(_runtime_auth, _opts), do: :ok

  defp governed_binding_evidence?(binding) do
    present?(binding.authority_ref || binding.authority_decision_ref) and
      present?(binding.credential_lease_ref) and present?(binding.native_auth_assertion_ref) and
      present?(binding.connector_instance_ref) and present?(binding.provider_account_ref) and
      present?(binding.target_ref) and present?(binding.operation_policy_ref)
  end

  defp governed_identity_evidence?(%__MODULE__{} = runtime_auth) do
    present?(runtime_auth.connector_instance.ref) and
      present?(runtime_auth.provider_account_identity.ref)
  end

  defp governed_validation_cause(%__MODULE__{} = runtime_auth) do
    binding = runtime_auth.connector_binding

    %{
      runtime_auth_mode: runtime_auth.mode,
      runtime_auth_scope: runtime_auth.execution_context.scope,
      execution_context_source: runtime_auth.execution_context.source,
      authority_ref: binding.authority_ref,
      authority_decision_ref: binding.authority_decision_ref,
      credential_handle_ref: binding.credential_handle_ref,
      credential_lease_ref: binding.credential_lease_ref,
      native_auth_assertion_ref: binding.native_auth_assertion_ref,
      connector_instance_ref: binding.connector_instance_ref,
      provider_account_ref: binding.provider_account_ref,
      target_ref: binding.target_ref,
      operation_policy_ref: binding.operation_policy_ref
    }
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

  defp normalize_provider_account_status(status) when is_atom(status), do: status

  defp normalize_provider_account_status(status) when is_binary(status) do
    case Enum.find(@provider_account_statuses, &(Atom.to_string(&1) == status)) do
      nil -> status
      atom -> atom
    end
  end

  defp normalize_provider_account_status(status), do: status

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

  defp replay_mode_option(opts) do
    case Keyword.get(opts, :replay_mode) do
      nil -> nil
      replay_mode when replay_mode in @replay_modes -> replay_mode
      replay_mode when is_binary(replay_mode) -> replay_mode_from_string(replay_mode)
      _replay_mode -> :invalid_replay_mode
    end
  end

  defp replay_mode_from_string(replay_mode) do
    case Enum.find(@replay_modes, &(Atom.to_string(&1) == replay_mode)) do
      nil -> :invalid_replay_mode
      atom -> atom
    end
  end

  defp invalid_replay_mode?(attrs) do
    replay_mode = Map.get(attrs, :replay_mode)
    not is_nil(replay_mode) and replay_mode not in @replay_modes
  end

  defp ref_list_option(opts, key) do
    opts
    |> Keyword.get(key, [])
    |> List.wrap()
    |> Enum.filter(&present?/1)
  end

  defp missing_handoff_refs(attrs) do
    Enum.reject(@handoff_required_refs, &present?(Map.get(attrs, &1)))
  end

  defp normalize_handoff_packet(%HandoffPacket{} = packet), do: Map.from_struct(packet)
  defp normalize_handoff_packet(packet) when is_map(packet), do: normalize_string_keys(packet)

  defp normalize_handoff_packet(other) do
    %{invalid_packet: other}
  end

  defp normalize_string_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {handoff_key(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp handoff_key(key) do
    Enum.find(
      @handoff_required_refs ++ [:authority_ref, :authority_decision_ref] ++ @handoff_context_refs,
      key,
      fn field ->
        Atom.to_string(field) == key
      end
    )
  end

  defp expected_handoff_mismatches(packet, opts) do
    opts
    |> Keyword.get(:expected_refs, %{})
    |> normalize_expected_refs()
    |> Enum.reduce([], fn {field, expected}, mismatches ->
      actual = Map.get(packet, field)

      if present?(expected) and expected != actual do
        mismatches ++ [{field, %{expected: expected, actual: actual}}]
      else
        mismatches
      end
    end)
  end

  defp normalize_expected_refs(expected) when is_list(expected),
    do: expected |> Map.new() |> normalize_expected_refs()

  defp normalize_expected_refs(expected) when is_map(expected),
    do: normalize_string_keys(expected)

  defp normalize_expected_refs(_expected), do: %{}

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

  defp first_present_map_value(sources, key) when is_list(sources) do
    Enum.find_value(sources, &map_value(&1, key))
  end

  defp first_present_map_value([first_source, second_source], first_key, second_key) do
    map_value(first_source, first_key) || map_value(second_source, second_key)
  end

  defp map_value(nil, _key), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp provider_account_evidence_forbidden_hits(evidence) when is_map(evidence) do
    @provider_account_evidence_forbidden_keys
    |> Enum.filter(fn key ->
      Map.has_key?(evidence, key) or Map.has_key?(evidence, Atom.to_string(key))
    end)
  end

  defp provider_account_evidence_forbidden_hits(_evidence), do: []

  defp governed_mode?(mode), do: mode in [:governed, "governed"]
  defp governed_scope?(scope), do: scope in [:governed, "governed"]
  defp governed_source?(source), do: source in [:governed_context, "governed_context"]

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value), do: not is_nil(value)
end
