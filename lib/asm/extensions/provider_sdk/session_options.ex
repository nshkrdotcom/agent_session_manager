defmodule ASM.Extensions.ProviderSDK.SessionOptions do
  @moduledoc false

  alias ASM.Error
  alias CliSubprocessCore.ExecutionSurface

  @legacy_execution_surface_keys [
    :surface_kind,
    :transport_options,
    :lease_ref,
    :surface_ref,
    :target_id,
    :boundary_class,
    :observability
  ]

  @session_only_keys [
    :execution_mode,
    :stream_timeout_ms,
    :queue_timeout_ms,
    :transport_call_timeout_ms,
    :workspace_root,
    :allowed_tools,
    :approval_posture,
    :lane,
    :driver_opts,
    :remote_node,
    :remote_cookie,
    :remote_connect_timeout_ms,
    :remote_rpc_timeout_ms,
    :remote_boot_lease_timeout_ms,
    :remote_bootstrap_mode,
    :remote_cwd,
    :remote_transport_call_timeout_ms,
    :run_module,
    :run_module_opts,
    :pipeline,
    :pipeline_ctx,
    :backend_module,
    :backend_opts
  ]

  @spec provider_opts(keyword()) :: keyword()
  def provider_opts(options) when is_list(options) do
    options
    |> maybe_put_cwd_from_workspace_root()
    |> Keyword.drop(@session_only_keys)
  end

  @spec extract_execution_surface(keyword()) ::
          {:ok, ExecutionSurface.t() | nil, keyword()} | {:error, Error.t()}
  def extract_execution_surface(options) when is_list(options) do
    legacy_keys =
      Enum.filter(@legacy_execution_surface_keys, &Keyword.has_key?(options, &1))

    if legacy_keys != [] do
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "legacy execution-surface keys are not supported: " <>
           Enum.map_join(legacy_keys, ", ", &inspect/1) <> ". Use :execution_surface instead."
       )}
    else
      stripped_options = Keyword.delete(options, :execution_surface)

      with {:ok, execution_surface} <-
             normalize_execution_surface_input(Keyword.get(options, :execution_surface)) do
        {:ok, execution_surface, stripped_options}
      end
    end
  end

  defp maybe_put_cwd_from_workspace_root(options) do
    case Keyword.get(options, :workspace_root) do
      value when is_binary(value) and value != "" ->
        Keyword.put_new(options, :cwd, value)

      _other ->
        options
    end
  end

  defp normalize_execution_surface(%ExecutionSurface{} = execution_surface) do
    case build_execution_surface(execution_surface_attrs(execution_surface)) do
      {:ok, normalized} -> normalized
      {:error, %Error{} = error} -> raise error
    end
  end

  defp normalize_execution_surface_input(nil), do: {:ok, nil}

  defp normalize_execution_surface_input(%ExecutionSurface{} = execution_surface) do
    {:ok, normalize_execution_surface(execution_surface)}
  end

  defp normalize_execution_surface_input(execution_surface) when is_list(execution_surface) do
    if Keyword.keyword?(execution_surface) do
      build_execution_surface(execution_surface)
    else
      {:error, invalid_execution_surface_error(execution_surface)}
    end
  end

  defp normalize_execution_surface_input(%{} = execution_surface) do
    execution_surface
    |> execution_surface_attrs()
    |> build_execution_surface()
  end

  defp normalize_execution_surface_input(execution_surface) do
    {:error, invalid_execution_surface_error(execution_surface)}
  end

  defp build_execution_surface(attrs) when is_list(attrs) do
    case ExecutionSurface.new(attrs) do
      {:ok, %ExecutionSurface{} = execution_surface} ->
        {:ok, execution_surface}

      {:error, reason} ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "invalid execution_surface derived from ASM session options: #{inspect(reason)}",
           cause: reason
         )}
    end
  end

  defp invalid_execution_surface_error(execution_surface) do
    Error.new(
      :config_invalid,
      :config,
      "execution_surface must be a CliSubprocessCore.ExecutionSurface, keyword list, or map, got: #{inspect(execution_surface)}",
      cause: execution_surface
    )
  end

  defp execution_surface_attrs(%ExecutionSurface{} = execution_surface) do
    [
      surface_kind: execution_surface.surface_kind,
      transport_options: execution_surface.transport_options,
      target_id: execution_surface.target_id,
      lease_ref: execution_surface.lease_ref,
      surface_ref: execution_surface.surface_ref,
      boundary_class: execution_surface.boundary_class,
      observability: execution_surface.observability
    ]
  end

  defp execution_surface_attrs(attrs) when is_map(attrs) do
    [
      surface_kind: Map.get(attrs, :surface_kind, Map.get(attrs, "surface_kind")),
      transport_options: Map.get(attrs, :transport_options, Map.get(attrs, "transport_options")),
      target_id: Map.get(attrs, :target_id, Map.get(attrs, "target_id")),
      lease_ref: Map.get(attrs, :lease_ref, Map.get(attrs, "lease_ref")),
      surface_ref: Map.get(attrs, :surface_ref, Map.get(attrs, "surface_ref")),
      boundary_class: Map.get(attrs, :boundary_class, Map.get(attrs, "boundary_class")),
      observability: Map.get(attrs, :observability, Map.get(attrs, "observability", %{}))
    ]
  end
end
