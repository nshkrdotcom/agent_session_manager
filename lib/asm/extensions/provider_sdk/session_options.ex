defmodule ASM.Extensions.ProviderSDK.SessionOptions do
  @moduledoc false

  alias ASM.Error
  alias CliSubprocessCore.ExecutionSurface

  @execution_surface_keys [
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
    execution_surface_attrs = Keyword.take(options, @execution_surface_keys)
    stripped_options = Keyword.drop(options, @execution_surface_keys)

    if execution_surface_attrs == [] do
      {:ok, nil, stripped_options}
    else
      case ExecutionSurface.new(execution_surface_attrs) do
        {:ok, %ExecutionSurface{} = execution_surface} ->
          {:ok, execution_surface, stripped_options}

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
  end

  defp maybe_put_cwd_from_workspace_root(options) do
    case Keyword.get(options, :workspace_root) do
      value when is_binary(value) and value != "" ->
        Keyword.put_new(options, :cwd, value)

      _other ->
        options
    end
  end
end
