defmodule ASM.Extensions.ProviderSDK.SessionOptions do
  @moduledoc false

  @session_only_keys [
    :execution_mode,
    :stream_timeout_ms,
    :queue_timeout_ms,
    :transport_call_timeout_ms,
    :surface_kind,
    :transport_options,
    :workspace_root,
    :allowed_tools,
    :approval_posture,
    :lease_ref,
    :surface_ref,
    :target_id,
    :boundary_class,
    :observability,
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

  defp maybe_put_cwd_from_workspace_root(options) do
    case Keyword.get(options, :workspace_root) do
      value when is_binary(value) and value != "" ->
        Keyword.put_new(options, :cwd, value)

      _other ->
        options
    end
  end
end
