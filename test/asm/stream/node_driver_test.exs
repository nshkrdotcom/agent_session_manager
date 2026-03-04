defmodule ASM.Stream.NodeDriverTest do
  use ASM.TestCase

  alias ASM.Error
  alias ASM.Execution.Config
  alias ASM.Stream.NodeDriver

  test "require_prestarted fails when remote preflight reports not ready" do
    context =
      base_context(%{
        remote_bootstrap_mode: :require_prestarted
      })

    assert {:error, %Error{} = error} =
             NodeDriver.start(
               context,
               ensure_connected_fun: fn _cfg -> :ok end,
               preflight_fun: fn _cfg -> {:error, :remote_not_ready} end,
               rpc_fun: fn _node, _mod, _fun, _args, _timeout -> :ok end,
               attach_fun: fn _run_pid, _transport_pid -> :ok end
             )

    assert error.message =~ "remote_not_ready"
  end

  test "ensure_started retries preflight after remote app bootstrap" do
    context = base_context(%{remote_bootstrap_mode: :ensure_started})
    transport_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(transport_pid, :kill) end)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    preflight_fun = fn _cfg ->
      Agent.get_and_update(counter, fn calls ->
        if calls == 0 do
          {{:error, :remote_not_ready}, calls + 1}
        else
          {:ok, calls}
        end
      end)
    end

    rpc_fun = fn
      _node, Application, :ensure_all_started, [:agent_session_manager], _timeout ->
        {:ok, [:agent_session_manager]}

      _node, ASM.Remote.TransportStarter, :start_transport, [_ctx], _timeout ->
        {:ok, transport_pid}

      _node, _mod, _fun, _args, _timeout ->
        :ok
    end

    assert {:ok, ^transport_pid} =
             NodeDriver.start(
               context,
               ensure_connected_fun: fn _cfg -> :ok end,
               preflight_fun: preflight_fun,
               rpc_fun: rpc_fun,
               attach_fun: fn _run_pid, _transport_pid -> :ok end
             )
  end

  test "attach failure triggers best-effort remote close" do
    context = base_context(%{remote_bootstrap_mode: :require_prestarted})
    remote_transport_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(remote_transport_pid, :kill) end)
    parent = self()

    assert {:error, %Error{} = error} =
             NodeDriver.start(
               context,
               ensure_connected_fun: fn _cfg -> :ok end,
               preflight_fun: fn _cfg -> :ok end,
               rpc_fun: fn _node,
                           ASM.Remote.TransportStarter,
                           :start_transport,
                           [_ctx],
                           _timeout ->
                 {:ok, remote_transport_pid}
               end,
               attach_fun: fn _run_pid, _transport_pid ->
                 {:error, Error.new(:transport_busy, :transport, "busy")}
               end,
               close_transport_fun: fn pid ->
                 send(parent, {:close_called, pid})
                 :ok
               end
             )

    assert error.message =~ "attach"
    assert_receive {:close_called, ^remote_transport_pid}
  end

  defp base_context(remote_overrides) do
    %{
      run_id: "run-node-driver",
      run_pid: self(),
      session_id: "session-node-driver",
      provider: :codex,
      prompt: "hello",
      provider_opts: [],
      driver_opts: [],
      execution_config: %Config{
        execution_mode: :remote_node,
        transport_call_timeout_ms: 5_000,
        remote:
          Map.merge(
            %{
              remote_node: :"asm@test-remote",
              remote_cookie: nil,
              remote_connect_timeout_ms: 1_000,
              remote_rpc_timeout_ms: 1_500,
              remote_boot_lease_timeout_ms: 200,
              remote_bootstrap_mode: :require_prestarted,
              remote_cwd: nil
            },
            remote_overrides
          )
      }
    }
  end
end
