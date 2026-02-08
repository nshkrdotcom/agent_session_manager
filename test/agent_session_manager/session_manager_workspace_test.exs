defmodule AgentSessionManager.SessionManagerWorkspaceTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.{Capability, Error}
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  defmodule WorkspaceSuccessAdapter do
    @behaviour AgentSessionManager.Ports.ProviderAdapter

    alias AgentSessionManager.Core.Capability

    @impl true
    def name(_adapter), do: "workspace-success"

    @impl true
    def capabilities(_adapter) do
      {:ok, [%Capability{name: "chat", type: :tool, enabled: true}]}
    end

    @impl true
    def execute(_adapter, run, _session, opts) do
      maybe_touch_workspace(opts)
      maybe_notify(opts)

      callback = Keyword.get(opts, :event_callback)

      emit(callback, run, :run_started, %{provider_session_id: "workspace-success-1"})
      emit(callback, run, :message_received, %{content: "workspace done"})
      emit(callback, run, :run_completed, %{})

      {:ok,
       %{
         output: %{content: "workspace done"},
         token_usage: %{input_tokens: 1, output_tokens: 1},
         events: []
       }}
    end

    @impl true
    def cancel(_adapter, run_id), do: {:ok, run_id}

    @impl true
    def validate_config(_adapter, _config), do: :ok

    defp maybe_touch_workspace(opts) do
      case Keyword.get(opts, :workspace_file) do
        nil -> :ok
        file -> File.write!(file, "changed by successful adapter\n")
      end
    end

    defp maybe_notify(opts) do
      case Keyword.get(opts, :notify_pid) do
        pid when is_pid(pid) -> send(pid, :adapter_executed)
        _ -> :ok
      end
    end

    defp emit(nil, _run, _type, _data), do: :ok

    defp emit(callback, run, type, data) do
      callback.(%{
        type: type,
        session_id: run.session_id,
        run_id: run.id,
        data: data,
        timestamp: DateTime.utc_now()
      })
    end
  end

  defmodule WorkspaceFailingAdapter do
    @behaviour AgentSessionManager.Ports.ProviderAdapter

    alias AgentSessionManager.Core.Capability

    @impl true
    def name(_adapter), do: "workspace-failing"

    @impl true
    def capabilities(_adapter) do
      {:ok, [%Capability{name: "chat", type: :tool, enabled: true}]}
    end

    @impl true
    def execute(_adapter, run, _session, opts) do
      workspace_file = Keyword.fetch!(opts, :workspace_file)
      File.write!(workspace_file, "changed before failure\n")

      if callback = Keyword.get(opts, :event_callback) do
        callback.(%{
          type: :run_started,
          session_id: run.session_id,
          run_id: run.id,
          data: %{},
          timestamp: DateTime.utc_now()
        })
      end

      {:error, Error.new(:provider_error, "forced failure")}
    end

    @impl true
    def cancel(_adapter, run_id), do: {:ok, run_id}

    @impl true
    def validate_config(_adapter, _config), do: :ok
  end

  setup ctx do
    {:ok, store} = setup_test_store(ctx)
    {:ok, store: store}
  end

  describe "execute_run/4 workspace integration" do
    test "captures snapshots and diff metadata when workspace is enabled", %{store: store} do
      repo = create_git_repo!()
      workspace_file = Path.join(repo, "file.txt")

      {:ok, session} =
        SessionManager.start_session(store, WorkspaceSuccessAdapter, %{
          agent_id: "workspace-agent"
        })

      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, run} =
        SessionManager.start_run(store, WorkspaceSuccessAdapter, session.id, %{prompt: "Go"})

      {:ok, result} =
        SessionManager.execute_run(store, WorkspaceSuccessAdapter, run.id,
          adapter_opts: [workspace_file: workspace_file],
          workspace: [
            enabled: true,
            path: repo,
            strategy: :auto,
            capture_patch: true,
            max_patch_bytes: 100_000
          ]
        )

      assert is_map(result.workspace)
      assert result.workspace.diff.files_changed >= 1
      assert "file.txt" in result.workspace.diff.changed_paths

      {:ok, stored_run} = SessionStore.get_run(store, run.id)
      assert stored_run.metadata.workspace.diff.files_changed >= 1

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      event_types = Enum.map(events, & &1.type)

      assert Enum.count(event_types, &(&1 == :workspace_snapshot_taken)) == 2
      assert :workspace_diff_computed in event_types
    end

    test "returns config error before execution when hash rollback is requested", %{store: store} do
      workspace_dir = create_plain_dir!()

      {:ok, session} =
        SessionManager.start_session(store, WorkspaceSuccessAdapter, %{
          agent_id: "workspace-agent"
        })

      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, run} =
        SessionManager.start_run(store, WorkspaceSuccessAdapter, session.id, %{prompt: "Go"})

      assert {:error, %Error{code: :validation_error}} =
               SessionManager.execute_run(store, WorkspaceSuccessAdapter, run.id,
                 adapter_opts: [notify_pid: self()],
                 workspace: [
                   enabled: true,
                   path: workspace_dir,
                   strategy: :hash,
                   rollback_on_failure: true
                 ]
               )

      refute_receive :adapter_executed
    end

    test "rolls back git workspace when run fails and rollback_on_failure is enabled", %{
      store: store
    } do
      repo = create_git_repo!()
      workspace_file = Path.join(repo, "file.txt")

      {:ok, session} =
        SessionManager.start_session(store, WorkspaceFailingAdapter, %{
          agent_id: "workspace-agent"
        })

      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, run} =
        SessionManager.start_run(store, WorkspaceFailingAdapter, session.id, %{prompt: "Go"})

      assert {:error, %Error{code: :provider_error}} =
               SessionManager.execute_run(store, WorkspaceFailingAdapter, run.id,
                 adapter_opts: [workspace_file: workspace_file],
                 workspace: [
                   enabled: true,
                   path: repo,
                   strategy: :git,
                   rollback_on_failure: true
                 ]
               )

      assert File.read!(workspace_file) == "base\n"
    end
  end

  defp create_git_repo! do
    repo = create_temp_dir!("session_workspace_git")
    file_path = Path.join(repo, "file.txt")

    File.write!(file_path, "base\n")

    run_git!(repo, ["init"])
    run_git!(repo, ["config", "user.email", "test@example.com"])
    run_git!(repo, ["config", "user.name", "Agent Session Manager Test"])
    run_git!(repo, ["add", "file.txt"])
    run_git!(repo, ["commit", "-m", "initial commit"])

    repo
  end

  defp create_plain_dir! do
    dir = create_temp_dir!("session_workspace_hash")
    File.write!(Path.join(dir, "file.txt"), "plain\n")
    dir
  end

  defp create_temp_dir!(prefix) do
    path =
      Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(path)
    cleanup_on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp run_git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
