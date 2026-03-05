Code.require_file("live_support.exs", __DIR__)

defmodule ASM.Examples.LivePubSub do
  @moduledoc false

  alias ASM.Error
  alias ASM.Examples.LiveSupport
  alias ASM.Extensions.PubSub

  def run! do
    provider = provider_from_env()
    prompt = LiveSupport.prompt_from_argv_or_default("Reply with exactly: PUBSUB_OK")
    provider_opts = provider_opts(provider)
    session_id = "live-pubsub-#{provider}-#{System.system_time(:millisecond)}"
    adapter = PubSub.local_adapter(registry: :asm_ext_pubsub_live, auto_start: true)

    LiveSupport.ensure_cli!(provider, Keyword.take(provider_opts, [:cli_path]))

    start_opts =
      provider_opts
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:session_id, session_id)

    with {:ok, broadcaster} <-
           PubSub.start_broadcaster(adapter: adapter, topic_scopes: [:all, :session, :run]),
         {:ok, session} <- ASM.start_session(start_opts) do
      try do
        all_topic = PubSub.all_topic()
        session_topic = PubSub.session_topic(session_id)

        assert_ok!(PubSub.subscribe(adapter, all_topic), "subscribe all topic")
        assert_ok!(PubSub.subscribe(adapter, session_topic), "subscribe session topic")

        IO.puts("[pubsub] subscribed topics: #{all_topic}, #{session_topic}")

        events =
          session
          |> ASM.stream(prompt, pipeline: [PubSub.broadcaster_plug(broadcaster)])
          |> Enum.to_list()

        Enum.each(events, &LiveSupport.print_event/1)

        result = ASM.Stream.final_result(events)
        assert_ok!(PubSub.flush_broadcaster(broadcaster, 2_000), "flush broadcaster")

        consumed = collect_pubsub_messages([])

        IO.puts("\n[live pubsub]")
        IO.puts("provider: #{provider}")
        IO.puts("session_id: #{session_id}")
        IO.puts("broadcast_messages: #{length(consumed)}")
        Enum.each(consumed, &print_consumed_message/1)
        LiveSupport.print_result(result)
      after
        _ = ASM.stop_session(session)
        if Process.alive?(broadcaster), do: GenServer.stop(broadcaster)
      end
    else
      {:error, %Error{} = error} ->
        IO.puts("failed to run live pubsub stream: #{Exception.message(error)}")
        System.halt(1)

      {:error, other} ->
        IO.puts("failed to run live pubsub stream: #{inspect(other)}")
        System.halt(1)
    end
  end

  defp collect_pubsub_messages(acc) do
    receive do
      {:asm_pubsub, topic, payload} ->
        collect_pubsub_messages([{topic, payload} | acc])
    after
      0 ->
        Enum.reverse(acc)
    end
  end

  defp print_consumed_message({topic, payload}) do
    IO.puts("  - topic=#{topic} event=#{payload.meta.event_kind} id=#{payload.meta.event_id}")
  end

  defp provider_from_env do
    case System.get_env("ASM_PUBSUB_PROVIDER", "claude") do
      "claude" -> :claude
      "gemini" -> :gemini
      "codex" -> :codex
      other -> raise ArgumentError, "unsupported ASM_PUBSUB_PROVIDER=#{inspect(other)}"
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

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp assert_ok!(:ok, _label), do: :ok

  defp assert_ok!({:error, %Error{} = error}, label) do
    IO.puts("#{label} failed: #{Exception.message(error)}")
    System.halt(1)
  end

  defp assert_ok!({:error, reason}, label) do
    IO.puts("#{label} failed: #{inspect(reason)}")
    System.halt(1)
  end
end

ASM.Examples.LivePubSub.run!()
