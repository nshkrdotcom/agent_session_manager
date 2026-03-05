Code.require_file("live_support.exs", __DIR__)

defmodule ASM.Examples.LivePersistence do
  @moduledoc false

  alias ASM.{Error, Event}
  alias ASM.Examples.LiveSupport
  alias ASM.Extensions.Persistence

  def run! do
    provider = provider_from_env()
    prompt = LiveSupport.prompt_from_argv_or_default("Reply with exactly: PERSIST_OK")
    missing_cwd = missing_cwd_path()
    file_path = persistence_file_path(provider)
    keep_file? = keep_file?()
    provider_opts = provider_opts(provider)

    LiveSupport.ensure_cli!(provider, Keyword.take(provider_opts, [:cli_path]))

    with {:ok, store} <- Persistence.start_store(:file, path: file_path, sync_writes: true),
         {:ok, writer} <- Persistence.start_writer(store: store, notify: self()) do
      try do
        session_id = "live-persist-#{provider}-#{System.system_time(:millisecond)}"

        start_opts =
          provider_opts
          |> Keyword.put(:provider, provider)
          |> Keyword.put(:session_id, session_id)

        with {:ok, session} <- ASM.start_session(start_opts) do
          try do
            {ok_events, ok_result} =
              stream_collect_result!(session, prompt, writer, [])

            ensure_no_error_events!(ok_events, "success path")

            {error_events, error_result} =
              stream_collect_result!(
                session,
                "Trigger controlled persistence error path",
                writer,
                cwd: missing_cwd
              )

            ensure_contains_error_event!(error_events, "error path")

            :ok = Persistence.flush_writer(writer)

            persisted_count =
              case Persistence.list_events(store, session_id) do
                {:ok, events} -> length(events)
                {:error, %Error{} = error} -> raise error
              end

            assert_no_writer_errors!()

            IO.puts("""

            [persistence]
            file: #{file_path}
            session_id: #{session_id}
            persisted_events: #{persisted_count}
            success_run_id: #{ok_result.run_id}
            error_run_id: #{error_result.run_id}
            """)

            print_rebuild!(store, session_id, ok_result.run_id, "success")
            print_rebuild!(store, session_id, error_result.run_id, "error")
          after
            _ = ASM.stop_session(session)
          end
        else
          {:error, %Error{} = error} ->
            IO.puts("failed to start session: #{Exception.message(error)}")
            System.halt(1)

          {:error, other} ->
            IO.puts("failed to start session: #{inspect(other)}")
            System.halt(1)
        end
      rescue
        error ->
          IO.puts("persistence live example failed: #{Exception.message(error)}")
          System.halt(1)
      after
        if Process.alive?(writer), do: GenServer.stop(writer)
        if Process.alive?(store), do: GenServer.stop(store)

        if keep_file? do
          IO.puts("kept persistence file: #{file_path}")
        else
          _ = File.rm(file_path)
          IO.puts("removed persistence file: #{file_path}")
        end
      end
    else
      {:error, %Error{} = error} ->
        IO.puts("failed to initialize persistence: #{Exception.message(error)}")
        System.halt(1)

      {:error, other} ->
        IO.puts("failed to initialize persistence: #{inspect(other)}")
        System.halt(1)
    end
  end

  defp stream_collect_result!(session, prompt, writer, run_opts) do
    events =
      session
      |> ASM.stream(prompt, Keyword.put(run_opts, :pipeline, [Persistence.writer_plug(writer)]))
      |> Enum.to_list()

    Enum.each(events, &LiveSupport.print_event/1)

    {events, ASM.Stream.final_result(events)}
  end

  defp ensure_no_error_events!(events, label) do
    errors =
      Enum.filter(events, fn
        %Event{kind: :error} -> true
        _ -> false
      end)

    if errors != [] do
      IO.puts("#{label} produced unexpected error events")
      Enum.each(errors, &print_error_event/1)
      System.halt(1)
    end
  end

  defp ensure_contains_error_event!(events, label) do
    case Enum.any?(events, &match?(%Event{kind: :error}, &1)) do
      true ->
        :ok

      false ->
        IO.puts("#{label} did not emit an expected error event")
        System.halt(1)
    end
  end

  defp print_rebuild!(store, session_id, run_id, label) do
    case Persistence.rebuild_run(store, session_id, run_id) do
      {:ok, %{result: result, events: events}} ->
        IO.puts("""
        [rebuild #{label}]
        run_id: #{run_id}
        stop_reason: #{inspect(result.stop_reason)}
        error: #{inspect(result.error)}
        replay_event_count: #{length(events)}
        """)

      {:error, %Error{} = error} ->
        IO.puts("failed to rebuild #{label} run #{run_id}: #{Exception.message(error)}")
        System.halt(1)
    end
  end

  defp assert_no_writer_errors! do
    errors = collect_writer_errors([])

    if errors != [] do
      IO.puts("persistence writer encountered append errors:")

      Enum.each(errors, fn {error, event} ->
        IO.puts("  - event=#{event.id}/#{event.kind} error=#{Exception.message(error)}")
      end)

      System.halt(1)
    end
  end

  defp collect_writer_errors(acc) do
    receive do
      {:asm_persistence_error, %Error{} = error, %Event{} = event} ->
        collect_writer_errors([{error, event} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp print_error_event(%Event{payload: %ASM.Message.Error{} = payload}) do
    IO.puts("  - [#{payload.kind}] #{payload.message}")
  end

  defp print_error_event(%Event{} = event) do
    IO.puts("  - [#{event.kind}] #{inspect(event.payload)}")
  end

  defp provider_from_env do
    case System.get_env("ASM_PERSIST_PROVIDER", "claude") do
      "claude" -> :claude
      "gemini" -> :gemini
      "codex" -> :codex
      other -> raise ArgumentError, "unsupported ASM_PERSIST_PROVIDER=#{inspect(other)}"
    end
  end

  defp provider_opts(provider) do
    []
    |> put_opt(:permission_mode, System.get_env("ASM_PERMISSION_MODE") || "auto")
    |> put_opt(:model, model_for(provider))
    |> put_opt(:cli_path, cli_path_for(provider))
  end

  defp model_for(:claude), do: System.get_env("ASM_CLAUDE_MODEL")
  defp model_for(:gemini), do: System.get_env("ASM_GEMINI_MODEL")
  defp model_for(:codex), do: System.get_env("ASM_CODEX_MODEL")

  defp cli_path_for(:claude), do: System.get_env("CLAUDE_CLI_PATH")
  defp cli_path_for(:gemini), do: System.get_env("GEMINI_CLI_PATH")
  defp cli_path_for(:codex), do: System.get_env("CODEX_PATH")

  defp persistence_file_path(provider) do
    case System.get_env("ASM_PERSIST_FILE") do
      nil ->
        Path.join(
          System.tmp_dir!(),
          "asm-live-persistence-#{provider}-#{System.system_time(:millisecond)}.events"
        )

      path ->
        path
    end
  end

  defp missing_cwd_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "asm-live-persistence-missing-#{System.unique_integer([:positive])}"
      )

    _ = File.rm_rf(path)
    path
  end

  defp keep_file? do
    System.get_env("ASM_PERSIST_KEEP_FILE") in ["1", "true", "TRUE"]
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end

ASM.Examples.LivePersistence.run!()
