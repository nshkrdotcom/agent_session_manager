defmodule ASM.Distributed.RemoteNodeExecutionTest do
  use ASM.SerialTestCase

  alias ASM.Error
  alias ASM.Remote.NodeConnector

  @moduletag :distributed

  setup do
    ensure_local_distribution!()
    NodeConnector.reset_cookie_book()

    original = Application.get_env(:agent_session_manager, ASM.ProviderRegistry)

    {:ok, peer, node} = start_peer!()

    workspace =
      Path.join(System.tmp_dir!(), "asm-remote-workspace-#{System.unique_integer([:positive])}")

    :ok = :rpc.call(node, File, :mkdir_p, [workspace])

    assert {:ok, _started} =
             :rpc.call(node, Application, :ensure_all_started, [:agent_session_manager])

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:agent_session_manager, ASM.ProviderRegistry)
      else
        Application.put_env(:agent_session_manager, ASM.ProviderRegistry, original)
      end

      File.rm_rf!(workspace)

      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, peer: peer, node: node, workspace: workspace}
  end

  test "happy path remote query end-to-end", %{node: node, workspace: workspace} do
    script = write_script!(codex_success_script("REMOTE_OK"))
    session = start_session!(:codex)

    assert {:ok, result} =
             ASM.query(session, "say ok",
               execution_mode: :remote_node,
               cli_path: script,
               driver_opts: [remote_node: node, remote_cwd: workspace]
             )

    assert result.text == "REMOTE_OK"
    assert :ok = ASM.stop_session(session)
  end

  test "unreachable node returns connect timeout or immediate connect failure" do
    session = start_session!(:codex)

    assert {:error, %Error{} = error} =
             ASM.query(session, "remote fail",
               execution_mode: :remote_node,
               driver_opts: [
                 remote_node: :nonexistent@nowhere,
                 remote_connect_timeout_ms: 300
               ]
             )

    assert String.contains?(error.message, "remote connect failed") or
             String.contains?(error.message, "remote_connect_timeout") or
             String.contains?(error.message, "remote_connect_failed")

    assert :ok = ASM.stop_session(session)
  end

  test "cookie conflict is deterministic", %{node: node, workspace: workspace} do
    script = write_script!(codex_success_script("COOKIE_OK"))
    session = start_session!(:codex)

    assert {:ok, result} =
             ASM.query(session, "cookie one",
               execution_mode: :remote_node,
               cli_path: script,
               driver_opts: [
                 remote_node: node,
                 remote_cookie: :cookie_a,
                 remote_cwd: workspace
               ]
             )

    assert result.text == "COOKIE_OK"

    assert {:error, %Error{} = error} =
             ASM.query(session, "cookie two",
               execution_mode: :remote_node,
               cli_path: script,
               driver_opts: [
                 remote_node: node,
                 remote_cookie: :cookie_b,
                 remote_cwd: workspace
               ]
             )

    assert error.message =~ "cookie_conflict"
    assert :ok = ASM.stop_session(session)
  end

  test "remote backend session is reaped after a completed run", %{
    node: node,
    workspace: workspace
  } do
    script = write_script!(codex_success_script("REMOTE_CLEAN"))
    session = start_session!(:codex)

    assert {:ok, result} =
             ASM.query(session, "cleanup",
               execution_mode: :remote_node,
               cli_path: script,
               driver_opts: [remote_node: node, remote_cwd: workspace]
             )

    assert result.text == "REMOTE_CLEAN"

    assert_eventually(fn ->
      remote_child_count(node) == 0
    end)

    assert :ok = ASM.stop_session(session)
  end

  test "session default remote with per-run local override", %{workspace: workspace} do
    script = write_script!(codex_success_script("LOCAL_OVERRIDE_OK"))

    session =
      start_session!(
        provider: :codex,
        execution_mode: :remote_node,
        driver_opts: [
          remote_node: :nonexistent@nowhere,
          remote_cwd: workspace
        ]
      )

    assert {:ok, result} =
             ASM.query(session, "local override",
               execution_mode: :local,
               cli_path: script
             )

    assert result.text == "LOCAL_OVERRIDE_OK"
    assert :ok = ASM.stop_session(session)
  end

  test "session default local with per-run remote override", %{node: node, workspace: workspace} do
    script = write_script!(codex_success_script("REMOTE_OVERRIDE_OK"))
    session = start_session!(:codex)

    assert {:ok, result} =
             ASM.query(session, "remote override",
               execution_mode: :remote_node,
               cli_path: script,
               driver_opts: [remote_node: node, remote_cwd: workspace]
             )

    assert result.text == "REMOTE_OVERRIDE_OK"
    assert :ok = ASM.stop_session(session)
  end

  test "auto lane keeps sdk preference metadata but runs the core backend remotely", %{
    node: node,
    workspace: workspace
  } do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> true
      runtime -> Code.ensure_loaded?(runtime)
    end)

    script = write_script!(codex_success_script("REMOTE_AUTO_LANE_OK"))
    session = start_session!(:codex)

    assert {:ok, result} =
             ASM.query(session, "remote auto lane",
               lane: :auto,
               execution_mode: :remote_node,
               cli_path: script,
               driver_opts: [remote_node: node, remote_cwd: workspace]
             )

    assert result.text == "REMOTE_AUTO_LANE_OK"
    assert result.metadata.requested_lane == :auto
    assert result.metadata.preferred_lane == :sdk
    assert result.metadata.lane == :core
    assert result.metadata.execution_mode == :remote_node
    assert result.metadata.lane_fallback_reason == :sdk_remote_unsupported
    assert result.metadata.backend == ASM.ProviderBackend.Core

    assert :ok = ASM.stop_session(session)
  end

  test "explicit sdk lane is rejected for remote execution", %{node: node, workspace: workspace} do
    put_runtime_loader(fn
      Codex.Runtime.Exec -> true
      runtime -> Code.ensure_loaded?(runtime)
    end)

    script = write_script!(codex_success_script("REMOTE_SDK_REJECT"))
    session = start_session!(:codex)

    assert {:error, %Error{} = error} =
             ASM.query(session, "remote sdk lane",
               lane: :sdk,
               execution_mode: :remote_node,
               cli_path: script,
               driver_opts: [remote_node: node, remote_cwd: workspace]
             )

    assert error.kind == :config_invalid
    assert error.message =~ "sdk lane"
    assert :ok = ASM.stop_session(session)
  end

  defp start_session!(provider) when is_atom(provider) do
    start_session!(provider: provider)
  end

  defp start_session!(opts) when is_list(opts) do
    session_id = "asm-distributed-#{System.unique_integer([:positive])}"
    {:ok, session} = ASM.start_session(Keyword.put(opts, :session_id, session_id))
    session
  end

  defp start_peer! do
    cookie = Node.get_cookie()

    args =
      Enum.flat_map(:code.get_path(), fn path ->
        [~c"-pa", to_charlist(path)]
      end) ++ [~c"-setcookie", cookie |> Atom.to_string() |> to_charlist()]

    :peer.start(%{
      name: :"asm_remote_peer_#{System.unique_integer([:positive])}",
      args: args
    })
  end

  defp ensure_local_distribution! do
    if Node.alive?() do
      :ok
    else
      _ = System.cmd("epmd", ["-daemon"])
      node_name = :"asm_test_#{System.unique_integer([:positive])}"
      start_distribution(node_name, :shortnames)
    end
  end

  defp start_distribution(node_name, name_domain) do
    case :net_kernel.start([node_name, name_domain]) do
      {:ok, _pid} ->
        Node.set_cookie(:asm_test_cookie)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, _reason} when name_domain == :shortnames ->
        start_distribution(node_name, :longnames)

      {:error, reason} ->
        flunk("failed to start local distribution: #{inspect(reason)}")
    end
  end

  defp remote_child_count(node) do
    case :rpc.call(node, DynamicSupervisor, :which_children, [ASM.Remote.BackendSupervisor]) do
      children when is_list(children) -> length(children)
      _ -> 0
    end
  end

  defp codex_success_script(text) do
    """
    #!/usr/bin/env bash
    set -euo pipefail
    echo '{"type":"thread.started","thread_id":"thread-1"}'
    echo '{"type":"turn.started"}'
    echo '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"#{text}"}}'
    echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """
  end

  defp write_script!(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "asm-distributed-remote-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, contents)
    File.chmod!(path, 0o755)
    path
  end

  defp put_runtime_loader(fun) when is_function(fun, 1) do
    Application.put_env(:agent_session_manager, ASM.ProviderRegistry, runtime_loader: fun)
  end

  defp assert_eventually(fun, attempts \\ 80)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0) do
    assert fun.()
  end
end
