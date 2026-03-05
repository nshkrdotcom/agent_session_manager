Code.require_file("live_support.exs", __DIR__)

defmodule ASM.Examples.LiveRendering do
  @moduledoc false

  alias ASM.Error
  alias ASM.Examples.LiveSupport
  alias ASM.Extensions.Rendering

  def run! do
    provider = provider_from_env()
    prompt = LiveSupport.prompt_from_argv_or_default("Reply with exactly: RENDER_OK")
    provider_opts = provider_opts(provider)
    session_id = "live-rendering-#{provider}-#{System.system_time(:millisecond)}"
    output_path = output_path(provider)
    keep_file? = keep_file?()
    renderer = renderer_from_env()

    LiveSupport.ensure_cli!(provider, Keyword.take(provider_opts, [:cli_path]))

    start_opts =
      provider_opts
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:session_id, session_id)

    with {:ok, collector} <- Agent.start_link(fn -> [] end),
         {:ok, session} <- ASM.start_session(start_opts) do
      try do
        callback = fn event, _iodata ->
          Agent.update(collector, fn acc -> [event | acc] end)
        end

        case Rendering.stream(ASM.stream(session, prompt),
               renderer: renderer,
               sinks: [
                 Rendering.tty_sink(),
                 Rendering.file_sink(path: output_path),
                 Rendering.callback_sink(callback: callback)
               ]
             ) do
          :ok ->
            events = Agent.get(collector, &Enum.reverse/1)
            result = ASM.Stream.final_result(events)

            IO.puts("\n[live rendering]")
            IO.puts("provider: #{provider}")
            IO.puts("session_id: #{session_id}")
            IO.puts("file_sink: #{output_path}")
            LiveSupport.print_result(result)

          {:error, %Error{} = error} ->
            IO.puts("live rendering failed: #{Exception.message(error)}")
            System.halt(1)
        end
      after
        _ = ASM.stop_session(session)
        if Process.alive?(collector), do: Agent.stop(collector)

        if keep_file? do
          IO.puts("kept render output file: #{output_path}")
        else
          _ = File.rm(output_path)
          IO.puts("removed render output file: #{output_path}")
        end
      end
    else
      {:error, %Error{} = error} ->
        IO.puts("failed to start live rendering session: #{Exception.message(error)}")
        System.halt(1)

      {:error, other} ->
        IO.puts("failed to start live rendering session: #{inspect(other)}")
        System.halt(1)
    end
  end

  defp provider_from_env do
    case System.get_env("ASM_RENDER_PROVIDER", "claude") do
      "claude" -> :claude
      "gemini" -> :gemini
      "codex" -> :codex
      other -> raise ArgumentError, "unsupported ASM_RENDER_PROVIDER=#{inspect(other)}"
    end
  end

  defp renderer_from_env do
    case System.get_env("ASM_RENDER_FORMAT", "compact") do
      "compact" -> Rendering.compact_renderer(color: true)
      "verbose" -> Rendering.verbose_renderer(color: true)
      other -> raise ArgumentError, "unsupported ASM_RENDER_FORMAT=#{inspect(other)}"
    end
  end

  defp output_path(provider) do
    case System.get_env("ASM_RENDER_FILE") do
      nil ->
        Path.join(
          System.tmp_dir!(),
          "asm-live-rendering-#{provider}-#{System.system_time(:millisecond)}.log"
        )

      path ->
        path
    end
  end

  defp keep_file? do
    System.get_env("ASM_RENDER_KEEP_FILE") in ["1", "true", "TRUE"]
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

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end

ASM.Examples.LiveRendering.run!()
