defmodule ASM.Remote.NodeConnector do
  @moduledoc """
  Remote node connection and preflight checks.
  """

  alias ASM.Remote.Capabilities

  @cookie_book :asm_remote_cookie_book

  @type remote_cfg :: %{
          required(:remote_node) => atom(),
          optional(:remote_cookie) => atom() | nil,
          optional(:remote_connect_timeout_ms) => pos_integer(),
          optional(:remote_rpc_timeout_ms) => pos_integer(),
          optional(:remote_boot_lease_timeout_ms) => pos_integer(),
          optional(:remote_bootstrap_mode) => :require_prestarted | :ensure_started,
          optional(:remote_cwd) => String.t() | nil
        }

  @spec ensure_connected(remote_cfg(), keyword()) ::
          :ok
          | {:error,
             :distribution_not_enabled
             | :remote_connect_timeout
             | :remote_connect_failed
             | :cookie_conflict}
  def ensure_connected(%{remote_node: remote_node} = cfg, opts \\ []) when is_atom(remote_node) do
    node_alive_fun = Keyword.get(opts, :node_alive_fun, &Node.alive?/0)
    set_cookie_fun = Keyword.get(opts, :set_cookie_fun, &Node.set_cookie/2)
    connect_fun = Keyword.get(opts, :connect_fun, &Node.connect/1)
    connect_timeout_ms = cfg[:remote_connect_timeout_ms] || 5_000

    if node_alive_fun.() do
      case maybe_apply_cookie(cfg, set_cookie_fun) do
        :ok ->
          connect_with_timeout(remote_node, connect_timeout_ms, connect_fun)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :distribution_not_enabled}
    end
  end

  @spec preflight(remote_cfg(), keyword()) ::
          :ok
          | {:error, :remote_not_ready | :remote_rpc_timeout | {:remote_rpc_failed, term()}}
          | {:error, {:remote_capability_mismatch, map()}}
          | {:error, {:remote_version_mismatch, map()}}
  def preflight(%{remote_node: remote_node} = cfg, opts \\ []) when is_atom(remote_node) do
    rpc_fun = Keyword.get(opts, :rpc_fun, &:rpc.call/5)
    rpc_timeout_ms = cfg[:remote_rpc_timeout_ms] || 15_000

    with {:ok, true} <-
           rpc_call(
             rpc_fun,
             remote_node,
             Code,
             :ensure_loaded?,
             [ASM.Remote.BackendStarter],
             rpc_timeout_ms
           ),
         {:ok, true} <-
           rpc_call(
             rpc_fun,
             remote_node,
             :erlang,
             :function_exported,
             [ASM.Remote.BackendStarter, :start_core_session, 1],
             rpc_timeout_ms
           ),
         {:ok, handshake} <-
           rpc_call(
             rpc_fun,
             remote_node,
             ASM.Remote.Capabilities,
             :handshake,
             [],
             rpc_timeout_ms
           ),
         :ok <- ensure_capabilities_compatible(handshake),
         :ok <- ensure_version_compatible(handshake),
         :ok <- ensure_otp_compatible(handshake),
         {:ok, supervisor_pid} <-
           rpc_call(
             rpc_fun,
             remote_node,
             Process,
             :whereis,
             [ASM.Remote.BackendSupervisor],
             rpc_timeout_ms
           ),
         :ok <- ensure_supervisor_ready(supervisor_pid) do
      :ok
    else
      {:ok, false} -> {:error, :remote_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reset_cookie_book() :: :ok
  def reset_cookie_book do
    ensure_cookie_book()
    :ets.delete_all_objects(@cookie_book)
    :ok
  end

  defp maybe_apply_cookie(cfg, set_cookie_fun) do
    case Map.get(cfg, :remote_cookie) do
      nil ->
        :ok

      cookie when is_atom(cookie) ->
        node = Map.fetch!(cfg, :remote_node)
        ensure_cookie_book()

        if :ets.insert_new(@cookie_book, {node, cookie}) do
          _ = set_cookie_fun.(node, cookie)
          :ok
        else
          cookie_lookup_result(node, cookie)
        end

      _other ->
        {:error, :cookie_conflict}
    end
  end

  defp cookie_lookup_result(node, cookie) do
    case :ets.lookup(@cookie_book, node) do
      [{^node, ^cookie}] -> :ok
      [{^node, _other_cookie}] -> {:error, :cookie_conflict}
      [] -> :ok
    end
  end

  defp connect_with_timeout(node, timeout_ms, connect_fun) do
    task = Task.async(fn -> connect_fun.(node) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :remote_connect_failed}
      {:ok, :ignored} -> {:error, :remote_connect_failed}
      nil -> {:error, :remote_connect_timeout}
      _ -> {:error, :remote_connect_failed}
    end
  end

  defp ensure_capabilities_compatible(%{capabilities: capabilities}) when is_list(capabilities) do
    required = Capabilities.required_capabilities()
    missing = required -- capabilities

    if missing == [] do
      :ok
    else
      {:error, {:remote_capability_mismatch, %{required: required, missing: missing}}}
    end
  end

  defp ensure_capabilities_compatible(_other) do
    {:error,
     {:remote_capability_mismatch,
      %{required: Capabilities.required_capabilities(), missing: :unknown}}}
  end

  defp ensure_version_compatible(%{asm_version: remote_version}) when is_binary(remote_version) do
    local_version = Capabilities.current_asm_version()

    if Capabilities.version_compatible?(local_version, remote_version) do
      :ok
    else
      {:error, {:remote_version_mismatch, %{local: local_version, remote: remote_version}}}
    end
  end

  defp ensure_version_compatible(_other) do
    {:error,
     {:remote_version_mismatch, %{local: Capabilities.current_asm_version(), remote: nil}}}
  end

  defp ensure_otp_compatible(%{otp_release: remote_release}) when is_binary(remote_release) do
    local_release = Capabilities.current_otp_release()

    if Capabilities.otp_major_compatible?(local_release, remote_release) do
      :ok
    else
      {:error,
       {:remote_version_mismatch, %{local_otp: local_release, remote_otp: remote_release}}}
    end
  end

  defp ensure_otp_compatible(_other) do
    {:error,
     {:remote_version_mismatch, %{local_otp: Capabilities.current_otp_release(), remote_otp: nil}}}
  end

  defp ensure_supervisor_ready(pid) when is_pid(pid), do: :ok
  defp ensure_supervisor_ready(_), do: {:error, :remote_not_ready}

  defp rpc_call(rpc_fun, node, mod, fun, args, timeout_ms) do
    case rpc_fun.(node, mod, fun, args, timeout_ms) do
      {:badrpc, :timeout} ->
        {:error, :remote_rpc_timeout}

      {:badrpc, {:EXIT, {:undef, _}}} ->
        {:error, :remote_not_ready}

      {:badrpc, :undef} ->
        {:error, :remote_not_ready}

      {:badrpc, reason} ->
        {:error, {:remote_rpc_failed, reason}}

      value ->
        {:ok, value}
    end
  end

  defp ensure_cookie_book do
    case :ets.whereis(@cookie_book) do
      :undefined ->
        :ets.new(@cookie_book, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  end
end
