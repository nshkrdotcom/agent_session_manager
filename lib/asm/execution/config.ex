defmodule ASM.Execution.Config do
  @moduledoc """
  Normalized execution-mode and execution-surface configuration with
  precedence-aware merging.
  """

  alias ASM.{Error, Permission}
  alias ASM.Schema.RemoteNode, as: RemoteNodeSchema

  @valid_execution_modes [:local, :remote_node]
  @valid_bootstrap_modes [:require_prestarted, :ensure_started]
  @valid_surface_kinds [:local_subprocess, :static_ssh, :leased_ssh, :guest_bridge]
  @valid_approval_postures [:manual, :auto, :none]

  @enforce_keys [:execution_mode, :transport_call_timeout_ms]
  defstruct [
    :execution_mode,
    :transport_call_timeout_ms,
    surface_kind: :local_subprocess,
    transport_options: [],
    workspace_root: nil,
    allowed_tools: [],
    approval_posture: nil,
    permission_mode: nil,
    provider_permission_mode: nil,
    lease_ref: nil,
    surface_ref: nil,
    target_id: nil,
    boundary_class: nil,
    observability: %{},
    remote: nil
  ]

  @type remote_t :: %{
          required(:remote_node) => atom(),
          required(:remote_cookie) => atom() | nil,
          required(:remote_connect_timeout_ms) => pos_integer(),
          required(:remote_rpc_timeout_ms) => pos_integer(),
          required(:remote_boot_lease_timeout_ms) => pos_integer(),
          required(:remote_bootstrap_mode) => :require_prestarted | :ensure_started,
          required(:remote_cwd) => String.t() | nil
        }

  @type t :: %__MODULE__{
          execution_mode: :local | :remote_node,
          transport_call_timeout_ms: pos_integer(),
          surface_kind: :local_subprocess | :static_ssh | :leased_ssh | :guest_bridge,
          transport_options: keyword(),
          workspace_root: String.t() | nil,
          allowed_tools: [String.t()],
          approval_posture: :manual | :auto | :none | nil,
          permission_mode: Permission.normalized_mode() | nil,
          provider_permission_mode: atom() | nil,
          lease_ref: String.t() | nil,
          surface_ref: String.t() | nil,
          target_id: String.t() | nil,
          boundary_class: atom() | nil,
          observability: map(),
          remote: remote_t() | nil
        }

  @spec resolve(keyword(), keyword(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def resolve(session_stream_opts, run_stream_opts, opts \\ [])
      when is_list(session_stream_opts) and is_list(run_stream_opts) and is_list(opts) do
    app_cfg = app_config()
    session_driver_opts = normalize_keyword(Keyword.get(session_stream_opts, :driver_opts, []))
    run_driver_opts = normalize_keyword(Keyword.get(run_stream_opts, :driver_opts, []))
    merged_driver_opts = Keyword.merge(session_driver_opts, run_driver_opts)

    explicit_driver? = Keyword.get(opts, :explicit_driver?, false)

    with {:ok, execution_mode} <-
           resolve_execution_mode(app_cfg, session_stream_opts, run_stream_opts, explicit_driver?),
         {:ok, transport_call_timeout_ms} <-
           resolve_transport_call_timeout(
             app_cfg,
             session_stream_opts,
             run_stream_opts,
             merged_driver_opts
           ),
         {:ok, surface_kind} <- resolve_surface_kind(session_stream_opts, run_stream_opts),
         {:ok, transport_options} <-
           resolve_surface_transport_options(session_stream_opts, run_stream_opts),
         {:ok, workspace_root} <-
           resolve_optional_binary(session_stream_opts, run_stream_opts, :workspace_root),
         {:ok, allowed_tools} <- resolve_allowed_tools(session_stream_opts, run_stream_opts),
         {:ok, approval_posture} <-
           resolve_approval_posture(session_stream_opts, run_stream_opts),
         {:ok, permission_mode, provider_permission_mode} <-
           resolve_permission_modes(
             session_stream_opts,
             run_stream_opts,
             Keyword.get(opts, :provider)
           ),
         {:ok, lease_ref} <-
           resolve_optional_binary(session_stream_opts, run_stream_opts, :lease_ref),
         {:ok, surface_ref} <-
           resolve_optional_binary(session_stream_opts, run_stream_opts, :surface_ref),
         {:ok, target_id} <-
           resolve_optional_binary(session_stream_opts, run_stream_opts, :target_id),
         {:ok, boundary_class} <-
           resolve_boundary_class(session_stream_opts, run_stream_opts),
         {:ok, observability} <-
           resolve_observability(session_stream_opts, run_stream_opts),
         {:ok, remote} <-
           resolve_remote_config(
             execution_mode,
             app_cfg,
             session_stream_opts,
             run_stream_opts,
             merged_driver_opts
           ) do
      {:ok,
       %__MODULE__{
         execution_mode: execution_mode,
         transport_call_timeout_ms: transport_call_timeout_ms,
         surface_kind: surface_kind,
         transport_options: transport_options,
         workspace_root: workspace_root,
         allowed_tools: allowed_tools,
         approval_posture: approval_posture,
         permission_mode: permission_mode,
         provider_permission_mode: provider_permission_mode,
         lease_ref: lease_ref,
         surface_ref: surface_ref,
         target_id: target_id,
         boundary_class: boundary_class,
         observability: observability,
         remote: remote
       }}
    end
  end

  defp resolve_execution_mode(_app_cfg, _session_stream_opts, _run_stream_opts, true) do
    {:ok, :local}
  end

  defp resolve_execution_mode(app_cfg, session_stream_opts, run_stream_opts, false) do
    mode =
      Keyword.get(run_stream_opts, :execution_mode) ||
        Keyword.get(session_stream_opts, :execution_mode) ||
        Keyword.get(app_cfg, :execution_mode, :local)

    if mode in @valid_execution_modes do
      {:ok, mode}
    else
      {:error,
       config_error(
         "invalid execution_mode #{inspect(mode)}; expected one of #{inspect(@valid_execution_modes)}"
       )}
    end
  end

  defp resolve_transport_call_timeout(
         app_cfg,
         session_stream_opts,
         run_stream_opts,
         merged_driver_opts
       ) do
    timeout_ms =
      Keyword.get(merged_driver_opts, :remote_transport_call_timeout_ms) ||
        Keyword.get(merged_driver_opts, :transport_call_timeout_ms) ||
        Keyword.get(run_stream_opts, :transport_call_timeout_ms) ||
        Keyword.get(session_stream_opts, :transport_call_timeout_ms) ||
        Keyword.get(app_cfg, :transport_call_timeout_ms, 5_000)

    case normalize_pos_integer(timeout_ms) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         config_error(
           "transport_call_timeout_ms must be a positive integer, got: #{inspect(timeout_ms)}"
         )}
    end
  end

  defp resolve_remote_config(
         :local,
         _app_cfg,
         _session_stream_opts,
         _run_stream_opts,
         _driver_opts
       ),
       do: {:ok, nil}

  defp resolve_remote_config(
         :remote_node,
         app_cfg,
         session_stream_opts,
         run_stream_opts,
         driver_opts
       ) do
    remote_node =
      Keyword.get(driver_opts, :remote_node) ||
        Keyword.get(run_stream_opts, :remote_node) ||
        Keyword.get(session_stream_opts, :remote_node) ||
        Keyword.get(app_cfg, :remote_node)

    with {:ok, remote_connect_timeout_ms} <-
           normalize_timeout(
             driver_opts,
             run_stream_opts,
             session_stream_opts,
             app_cfg,
             :remote_connect_timeout_ms,
             5_000
           ),
         {:ok, remote_rpc_timeout_ms} <-
           normalize_timeout(
             driver_opts,
             run_stream_opts,
             session_stream_opts,
             app_cfg,
             :remote_rpc_timeout_ms,
             15_000
           ),
         {:ok, remote_boot_lease_timeout_ms} <-
           normalize_timeout(
             driver_opts,
             run_stream_opts,
             session_stream_opts,
             app_cfg,
             :remote_boot_lease_timeout_ms,
             10_000
           ),
         {:ok, remote_bootstrap_mode} <-
           normalize_bootstrap_mode(
             Keyword.get(driver_opts, :remote_bootstrap_mode) ||
               Keyword.get(run_stream_opts, :remote_bootstrap_mode) ||
               Keyword.get(session_stream_opts, :remote_bootstrap_mode) ||
               Keyword.get(app_cfg, :remote_bootstrap_mode, :require_prestarted)
           ),
         {:ok, remote} <-
           build_remote_config(
             remote_node,
             Keyword.get(driver_opts, :remote_cookie),
             remote_connect_timeout_ms,
             remote_rpc_timeout_ms,
             remote_boot_lease_timeout_ms,
             remote_bootstrap_mode,
             Keyword.get(driver_opts, :remote_cwd)
           ) do
      {:ok, remote}
    end
  end

  defp normalize_timeout(driver_opts, run_stream_opts, session_stream_opts, app_cfg, key, default) do
    value =
      Keyword.get(driver_opts, key) ||
        Keyword.get(run_stream_opts, key) ||
        Keyword.get(session_stream_opts, key) ||
        Keyword.get(app_cfg, key, default)

    case normalize_pos_integer(value) do
      {:ok, timeout} ->
        {:ok, timeout}

      :error ->
        {:error, config_error("#{key} must be a positive integer, got: #{inspect(value)}")}
    end
  end

  defp normalize_bootstrap_mode(mode) when mode in @valid_bootstrap_modes, do: {:ok, mode}

  defp normalize_bootstrap_mode(mode) do
    {:error,
     config_error(
       "remote_bootstrap_mode must be one of #{inspect(@valid_bootstrap_modes)}, got: #{inspect(mode)}"
     )}
  end

  defp normalize_pos_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_pos_integer(_value), do: :error

  defp build_remote_config(
         remote_node,
         remote_cookie,
         remote_connect_timeout_ms,
         remote_rpc_timeout_ms,
         remote_boot_lease_timeout_ms,
         remote_bootstrap_mode,
         remote_cwd
       ) do
    attrs =
      %{
        remote_connect_timeout_ms: remote_connect_timeout_ms,
        remote_rpc_timeout_ms: remote_rpc_timeout_ms,
        remote_boot_lease_timeout_ms: remote_boot_lease_timeout_ms,
        remote_bootstrap_mode: remote_bootstrap_mode
      }
      |> maybe_put(:remote_node, remote_node)
      |> maybe_put(:remote_cookie, remote_cookie)
      |> maybe_put(:remote_cwd, remote_cwd)

    case RemoteNodeSchema.parse(attrs) do
      {:ok, remote} ->
        {:ok, remote}

      {:error, {:invalid_remote_node_config, details}} ->
        {:error, config_error(details.message)}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp resolve_surface_kind(session_stream_opts, run_stream_opts) do
    session_surface_kind = Keyword.get(session_stream_opts, :surface_kind)
    run_surface_kind = Keyword.get(run_stream_opts, :surface_kind, session_surface_kind)
    normalize_surface_kind(run_surface_kind)
  end

  defp resolve_surface_transport_options(session_stream_opts, run_stream_opts) do
    with {:ok, session_transport_options} <-
           normalize_transport_options(Keyword.get(session_stream_opts, :transport_options)),
         {:ok, run_transport_options} <-
           normalize_transport_options(Keyword.get(run_stream_opts, :transport_options)) do
      {:ok, Keyword.merge(session_transport_options, run_transport_options)}
    end
  end

  defp resolve_allowed_tools(session_stream_opts, run_stream_opts) do
    session_allowed_tools = Keyword.get(session_stream_opts, :allowed_tools, [])
    allowed_tools = Keyword.get(run_stream_opts, :allowed_tools, session_allowed_tools)

    allowed_tools
    |> normalize_string_list()
    |> case do
      {:ok, values} -> {:ok, values}
      {:error, reason} -> {:error, config_error(reason)}
    end
  end

  defp resolve_approval_posture(session_stream_opts, run_stream_opts) do
    approval_posture =
      Keyword.get(
        run_stream_opts,
        :approval_posture,
        Keyword.get(session_stream_opts, :approval_posture)
      )

    case normalize_approval_posture(approval_posture) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, config_error(reason)}
    end
  end

  defp resolve_permission_modes(session_stream_opts, run_stream_opts, provider) do
    permission_mode =
      Keyword.get(
        run_stream_opts,
        :permission_mode,
        Keyword.get(session_stream_opts, :permission_mode)
      )

    case normalize_permission_mode(permission_mode, provider) do
      {:ok, normalized, native} ->
        {:ok, normalized, native}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, config_error(reason)}
    end
  end

  defp resolve_optional_binary(session_stream_opts, run_stream_opts, key) do
    value = Keyword.get(run_stream_opts, key, Keyword.get(session_stream_opts, key))

    if is_nil(value) or (is_binary(value) and value != "") do
      {:ok, value}
    else
      {:error, config_error("#{key} must be a non-empty string, got: #{inspect(value)}")}
    end
  end

  defp resolve_boundary_class(session_stream_opts, run_stream_opts) do
    boundary_class =
      Keyword.get(
        run_stream_opts,
        :boundary_class,
        Keyword.get(session_stream_opts, :boundary_class)
      )

    cond do
      is_nil(boundary_class) ->
        {:ok, nil}

      is_atom(boundary_class) ->
        {:ok, boundary_class}

      true ->
        {:error, config_error("boundary_class must be an atom, got: #{inspect(boundary_class)}")}
    end
  end

  defp resolve_observability(session_stream_opts, run_stream_opts) do
    session_observability = Keyword.get(session_stream_opts, :observability, %{})
    run_observability = Keyword.get(run_stream_opts, :observability, %{})

    cond do
      not is_map(session_observability) ->
        {:error,
         config_error("observability must be a map, got: #{inspect(session_observability)}")}

      not is_map(run_observability) ->
        {:error, config_error("observability must be a map, got: #{inspect(run_observability)}")}

      true ->
        {:ok, Map.merge(session_observability, run_observability)}
    end
  end

  defp normalize_approval_posture(nil), do: {:ok, nil}
  defp normalize_approval_posture(value) when value in @valid_approval_postures, do: {:ok, value}

  defp normalize_approval_posture(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "manual" -> {:ok, :manual}
      "auto" -> {:ok, :auto}
      "none" -> {:ok, :none}
      _other -> {:error, "approval_posture must be :manual, :auto, or :none"}
    end
  end

  defp normalize_approval_posture(value) do
    {:error, "approval_posture must be :manual, :auto, or :none, got: #{inspect(value)}"}
  end

  defp normalize_surface_kind(nil), do: {:ok, :local_subprocess}

  defp normalize_surface_kind(surface_kind) when surface_kind in @valid_surface_kinds,
    do: {:ok, surface_kind}

  defp normalize_surface_kind(surface_kind) do
    {:error,
     config_error(
       "surface_kind must be one of #{inspect(@valid_surface_kinds)}, got: #{inspect(surface_kind)}"
     )}
  end

  defp normalize_transport_options(nil), do: {:ok, []}

  defp normalize_transport_options(options) when is_list(options) do
    if Keyword.keyword?(options) do
      {:ok, options}
    else
      {:error,
       config_error(
         "transport_options must be a keyword list or atom-keyed map, got: #{inspect(options)}"
       )}
    end
  end

  defp normalize_transport_options(options) when is_map(options) do
    if Enum.all?(Map.keys(options), &is_atom/1) do
      {:ok, Enum.into(options, [])}
    else
      {:error, config_error("transport_options map keys must be atoms, got: #{inspect(options)}")}
    end
  end

  defp normalize_transport_options(options) do
    {:error,
     config_error(
       "transport_options must be a keyword list or atom-keyed map, got: #{inspect(options)}"
     )}
  end

  defp normalize_permission_mode(nil, _provider), do: {:ok, nil, nil}

  defp normalize_permission_mode(permission_mode, provider) when is_atom(provider) do
    case Permission.normalize(provider, permission_mode) do
      {:ok, %{normalized: normalized, native: native}} ->
        {:ok, normalized, native}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp normalize_permission_mode(permission_mode, _provider) do
    normalized_modes = Permission.normalized_modes()

    case normalize_permission_mode_atom(permission_mode) do
      {:ok, normalized} ->
        if normalized in normalized_modes do
          {:ok, normalized, nil}
        else
          {:error,
           "permission_mode must be one of #{inspect(normalized_modes)}, got: #{inspect(normalized)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_permission_mode_atom(permission_mode) when is_atom(permission_mode),
    do: {:ok, permission_mode}

  defp normalize_permission_mode_atom(permission_mode) when is_binary(permission_mode) do
    permission_mode
    |> String.trim()
    |> String.downcase()
    |> case do
      "default" -> {:ok, :default}
      "auto" -> {:ok, :auto}
      "bypass" -> {:ok, :bypass}
      "plan" -> {:ok, :plan}
      _other -> {:error, "permission_mode must be a supported normalized mode"}
    end
  end

  defp normalize_permission_mode_atom(permission_mode) do
    {:error, "permission_mode must be an atom or string, got: #{inspect(permission_mode)}"}
  end

  defp normalize_string_list(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn
      value, {:ok, acc} when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          {:halt, {:error, "allowed_tools entries must be non-empty strings"}}
        else
          {:cont, {:ok, acc ++ [trimmed]}}
        end

      value, {:ok, acc} when is_atom(value) ->
        {:cont, {:ok, acc ++ [Atom.to_string(value)]}}

      value, _acc ->
        {:halt,
         {:error, "allowed_tools entries must be strings or atoms, got: #{inspect(value)}"}}
    end)
  end

  defp normalize_string_list(values) do
    {:error, "allowed_tools must be a list, got: #{inspect(values)}"}
  end

  defp normalize_keyword(value) when is_list(value), do: value
  defp normalize_keyword(_value), do: []

  defp app_config do
    defaults = [
      execution_mode: :local,
      remote_connect_timeout_ms: 5_000,
      remote_rpc_timeout_ms: 15_000,
      remote_boot_lease_timeout_ms: 10_000,
      remote_bootstrap_mode: :require_prestarted,
      transport_call_timeout_ms: 5_000
    ]

    Keyword.merge(defaults, Application.get_env(:agent_session_manager, __MODULE__, []))
  end

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end
end
