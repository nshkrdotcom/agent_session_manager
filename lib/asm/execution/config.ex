defmodule ASM.Execution.Config do
  @moduledoc """
  Normalized execution-mode, execution-surface, and execution-environment
  configuration with precedence-aware merging.
  """

  alias ASM.{Error, Execution.Environment, Permission}
  alias ASM.Schema.RemoteNode, as: RemoteNodeSchema
  alias CliSubprocessCore.ExecutionSurface

  @execution_surface_keys [
    :contract_version,
    :surface_kind,
    :transport_options,
    :target_id,
    :lease_ref,
    :surface_ref,
    :boundary_class,
    :observability
  ]
  @valid_execution_modes [:local, :remote_node]
  @valid_bootstrap_modes [:require_prestarted, :ensure_started]
  @legacy_execution_surface_keys [
    :surface_kind,
    :transport_options,
    :lease_ref,
    :surface_ref,
    :target_id,
    :boundary_class,
    :observability
  ]

  @enforce_keys [:execution_mode, :transport_call_timeout_ms]
  defstruct execution_mode: :local,
            transport_call_timeout_ms: 5_000,
            execution_surface: %ExecutionSurface{},
            execution_environment: %Environment{},
            provider_permission_mode: nil,
            remote: nil

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
          execution_surface: ExecutionSurface.t(),
          execution_environment: Environment.t(),
          provider_permission_mode: atom() | nil,
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

    with :ok <- reject_legacy_execution_surface_keys(session_stream_opts, run_stream_opts),
         {:ok, execution_mode} <-
           resolve_execution_mode(app_cfg, session_stream_opts, run_stream_opts, explicit_driver?),
         {:ok, transport_call_timeout_ms} <-
           resolve_transport_call_timeout(
             app_cfg,
             session_stream_opts,
             run_stream_opts,
             merged_driver_opts
           ),
         {:ok, session_execution_surface} <- resolve_execution_surface(session_stream_opts),
         {:ok, run_execution_surface} <- resolve_execution_surface(run_stream_opts),
         {:ok, execution_surface} <-
           merge_execution_surfaces(session_execution_surface, run_execution_surface),
         {:ok, session_execution_environment_attrs} <-
           resolve_execution_environment_attrs(session_stream_opts),
         {:ok, run_execution_environment_attrs} <-
           resolve_execution_environment_attrs(run_stream_opts),
         {:ok, execution_environment} <-
           merge_execution_environments(
             session_execution_environment_attrs,
             run_execution_environment_attrs
           ),
         {:ok, provider_permission_mode} <-
           resolve_provider_permission_mode(
             execution_environment.permission_mode,
             Keyword.get(opts, :provider)
           ),
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
         execution_surface: execution_surface,
         execution_environment: execution_environment,
         provider_permission_mode: provider_permission_mode,
         remote: remote
       }}
    end
  end

  @spec to_execution_surface(t()) :: ExecutionSurface.t()
  def to_execution_surface(%__MODULE__{
        execution_surface: %ExecutionSurface{} = execution_surface
      }) do
    execution_surface
  end

  @spec to_execution_environment(t()) :: Environment.t()
  def to_execution_environment(%__MODULE__{
        execution_environment: %Environment{} = execution_environment
      }) do
    execution_environment
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
           ) do
      build_remote_config(
        remote_node,
        Keyword.get(driver_opts, :remote_cookie),
        remote_connect_timeout_ms,
        remote_rpc_timeout_ms,
        remote_boot_lease_timeout_ms,
        remote_bootstrap_mode,
        Keyword.get(driver_opts, :remote_cwd)
      )
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

  defp reject_legacy_execution_surface_keys(session_stream_opts, run_stream_opts) do
    legacy_keys =
      @legacy_execution_surface_keys
      |> Enum.filter(
        &(Keyword.has_key?(session_stream_opts, &1) or Keyword.has_key?(run_stream_opts, &1))
      )

    if legacy_keys == [] do
      :ok
    else
      {:error,
       config_error(
         "legacy execution-surface keys are not supported: " <>
           Enum.map_join(legacy_keys, ", ", &inspect/1) <>
           ". Use :execution_surface instead."
       )}
    end
  end

  defp resolve_execution_surface(opts) when is_list(opts) do
    case Keyword.get(opts, :execution_surface) do
      nil ->
        {:ok, nil}

      %ExecutionSurface{} = execution_surface ->
        normalize_execution_surface_input(execution_surface)

      execution_surface when is_list(execution_surface) ->
        if Keyword.keyword?(execution_surface) do
          normalize_execution_surface_input(execution_surface)
        else
          {:error,
           config_error(
             "execution_surface must be a CliSubprocessCore.ExecutionSurface, keyword list, or map, got: #{inspect(execution_surface)}"
           )}
        end

      %{} = execution_surface ->
        normalize_execution_surface_input(execution_surface)

      execution_surface ->
        {:error,
         config_error(
           "execution_surface must be a CliSubprocessCore.ExecutionSurface, keyword list, or map, got: #{inspect(execution_surface)}"
         )}
    end
  end

  defp merge_execution_surfaces(nil, nil), do: normalize_execution_surface_attrs([])

  defp merge_execution_surfaces(attrs, nil) when is_list(attrs),
    do: normalize_execution_surface_attrs(attrs)

  defp merge_execution_surfaces(nil, attrs) when is_list(attrs),
    do: normalize_execution_surface_attrs(attrs)

  defp merge_execution_surfaces(
         session_execution_surface_attrs,
         run_execution_surface_attrs
       ) do
    session_transport_options =
      Keyword.get(session_execution_surface_attrs, :transport_options, [])

    run_transport_options = Keyword.get(run_execution_surface_attrs, :transport_options, [])
    session_observability = Keyword.get(session_execution_surface_attrs, :observability, %{})
    run_observability = Keyword.get(run_execution_surface_attrs, :observability, %{})

    normalize_execution_surface_attrs(
      session_execution_surface_attrs
      |> Keyword.merge(run_execution_surface_attrs)
      |> Keyword.put(
        :transport_options,
        Keyword.merge(session_transport_options, run_transport_options)
      )
      |> Keyword.put(:observability, Map.merge(session_observability, run_observability))
    )
  end

  defp normalize_execution_surface_struct(%ExecutionSurface{} = execution_surface) do
    execution_surface
    |> execution_surface_attrs()
    |> normalize_execution_surface_attrs()
  end

  defp normalize_execution_surface_attrs(attrs) when is_list(attrs) do
    case ExecutionSurface.new(attrs) do
      {:ok, %ExecutionSurface{} = execution_surface} ->
        {:ok, execution_surface}

      {:error, reason} ->
        {:error, config_error("execution_surface is invalid: #{inspect(reason)}")}
    end
  end

  defp normalize_execution_surface_input(%ExecutionSurface{} = execution_surface) do
    with {:ok, normalized} <- normalize_execution_surface_struct(execution_surface) do
      {:ok, execution_surface_attrs(normalized)}
    end
  end

  defp normalize_execution_surface_input(execution_surface) when is_list(execution_surface) do
    normalized_keys = Keyword.keys(execution_surface)

    with {:ok, normalized} <- normalize_execution_surface_attrs(execution_surface) do
      {:ok, execution_surface_attrs(normalized, normalized_keys)}
    end
  end

  defp normalize_execution_surface_input(execution_surface) when is_map(execution_surface) do
    normalized_keys = execution_surface_present_keys(execution_surface)

    with {:ok, normalized} <-
           execution_surface
           |> execution_surface_attrs()
           |> normalize_execution_surface_attrs() do
      {:ok, execution_surface_attrs(normalized, normalized_keys)}
    end
  end

  defp execution_surface_attrs(%ExecutionSurface{} = execution_surface) do
    execution_surface_attrs(execution_surface, @execution_surface_keys)
  end

  defp execution_surface_attrs(attrs) when is_map(attrs) do
    [
      contract_version: Map.get(attrs, :contract_version, Map.get(attrs, "contract_version")),
      surface_kind: Map.get(attrs, :surface_kind, Map.get(attrs, "surface_kind")),
      transport_options: Map.get(attrs, :transport_options, Map.get(attrs, "transport_options")),
      target_id: Map.get(attrs, :target_id, Map.get(attrs, "target_id")),
      lease_ref: Map.get(attrs, :lease_ref, Map.get(attrs, "lease_ref")),
      surface_ref: Map.get(attrs, :surface_ref, Map.get(attrs, "surface_ref")),
      boundary_class: Map.get(attrs, :boundary_class, Map.get(attrs, "boundary_class")),
      observability: Map.get(attrs, :observability, Map.get(attrs, "observability", %{}))
    ]
  end

  defp execution_surface_attrs(%ExecutionSurface{} = execution_surface, keys) do
    [
      contract_version: execution_surface.contract_version,
      surface_kind: execution_surface.surface_kind,
      transport_options: execution_surface.transport_options,
      target_id: execution_surface.target_id,
      lease_ref: execution_surface.lease_ref,
      surface_ref: execution_surface.surface_ref,
      boundary_class: execution_surface.boundary_class,
      observability: execution_surface.observability
    ]
    |> Keyword.take(keys)
  end

  defp execution_surface_present_keys(attrs) when is_map(attrs) do
    Enum.filter(@execution_surface_keys, fn key ->
      Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
    end)
  end

  defp resolve_execution_environment_attrs(opts) when is_list(opts) do
    with {:ok, nested_attrs} <-
           normalize_execution_environment_input(Keyword.get(opts, :execution_environment)),
         {:ok, top_level_attrs} <- normalize_top_level_execution_environment_attrs(opts) do
      {:ok, merge_present_attrs(nested_attrs, top_level_attrs, Environment.keys())}
    end
  end

  defp normalize_execution_environment_input(nil), do: {:ok, []}

  defp normalize_execution_environment_input(input),
    do: normalize_execution_environment_attrs(input)

  defp normalize_top_level_execution_environment_attrs(opts) when is_list(opts) do
    attrs =
      Enum.reduce(Environment.keys(), [], fn key, acc ->
        if Keyword.has_key?(opts, key) do
          [{key, Keyword.get(opts, key)} | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    normalize_execution_environment_attrs(attrs)
  end

  defp normalize_execution_environment_attrs(attrs) do
    case Environment.normalize_attrs(attrs) do
      {:ok, normalized_attrs} ->
        {:ok, normalized_attrs}

      {:error, reason} ->
        {:error, config_error("execution_environment is invalid: #{inspect(reason)}")}
    end
  end

  defp merge_execution_environments(session_attrs, run_attrs)
       when is_list(session_attrs) and is_list(run_attrs) do
    merged_attrs = merge_present_attrs(session_attrs, run_attrs, Environment.keys())

    case Environment.new(merged_attrs) do
      {:ok, %Environment{} = environment} ->
        {:ok, environment}

      {:error, reason} ->
        {:error, config_error("execution_environment is invalid: #{inspect(reason)}")}
    end
  end

  defp merge_present_attrs(left_attrs, right_attrs, keys)
       when is_list(left_attrs) and is_list(right_attrs) and is_list(keys) do
    Enum.reduce(keys, [], fn key, acc ->
      cond do
        Keyword.has_key?(right_attrs, key) ->
          [{key, Keyword.get(right_attrs, key)} | acc]

        Keyword.has_key?(left_attrs, key) ->
          [{key, Keyword.get(left_attrs, key)} | acc]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp resolve_provider_permission_mode(nil, _provider), do: {:ok, nil}

  defp resolve_provider_permission_mode(permission_mode, provider) when is_atom(provider) do
    case Permission.normalize(provider, permission_mode) do
      {:ok, %{native: native}} ->
        {:ok, native}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp resolve_provider_permission_mode(_permission_mode, _provider), do: {:ok, nil}

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
