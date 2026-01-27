defmodule AgentSessionManager.SupertesterCase.Helpers do
  @moduledoc false

  alias AgentSessionManager.Adapters.InMemorySessionStore
  alias AgentSessionManager.Test.{Fixtures, MockProviderAdapter}

  import ExUnit.Callbacks, only: [on_exit: 1]
  import ExUnit.Assertions, only: [assert: 2]

  @spec setup_test_store(map()) :: {:ok, pid()}
  def setup_test_store(_ctx \\ %{}) do
    {:ok, store} = InMemorySessionStore.start_link([])

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store, :normal)
    end)

    {:ok, store}
  end

  @spec setup_test_adapter(map(), keyword()) :: {:ok, pid()}
  def setup_test_adapter(_ctx \\ %{}, opts \\ []) do
    adapter_opts =
      Keyword.merge(
        [
          capabilities: Fixtures.provider_capabilities(:full_claude),
          execution_mode: :instant
        ],
        opts
      )

    {:ok, adapter} = MockProviderAdapter.start_link(adapter_opts)

    on_exit(fn ->
      if Process.alive?(adapter), do: MockProviderAdapter.stop(adapter)
    end)

    {:ok, adapter}
  end

  @spec setup_test_infrastructure(map(), keyword()) :: {:ok, map()}
  def setup_test_infrastructure(ctx \\ %{}, opts \\ []) do
    {:ok, store} = setup_test_store(ctx)
    {:ok, adapter} = setup_test_adapter(ctx, opts)
    {:ok, %{store: store, adapter: adapter}}
  end

  @spec build_test_session(keyword()) :: AgentSessionManager.Core.Session.t()
  def build_test_session(opts \\ []) do
    Fixtures.build_session(opts)
  end

  @spec build_test_run(keyword()) :: AgentSessionManager.Core.Run.t()
  def build_test_run(opts \\ []) do
    Fixtures.build_run(opts)
  end

  @spec wait_for_server_ready(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def wait_for_server_ready(server, timeout \\ 5000) do
    Supertester.OTPHelpers.wait_for_genserver_sync(server, timeout)
  end

  @spec assert_server_alive(pid() | GenServer.server()) :: :ok
  def assert_server_alive(server) when is_pid(server) do
    assert Process.alive?(server), "Expected process #{inspect(server)} to be alive"
    :ok
  end

  def assert_server_alive(server) do
    pid = GenServer.whereis(server)
    assert pid != nil, "Expected server #{inspect(server)} to be registered"
    assert Process.alive?(pid), "Expected server #{inspect(server)} to be alive"
    :ok
  end

  @spec assert_all_servers_alive([pid() | GenServer.server()]) :: :ok
  def assert_all_servers_alive(servers) do
    Enum.each(servers, &assert_server_alive/1)
    :ok
  end

  @spec safe_stop(pid() | GenServer.server()) :: :ok
  def safe_stop(server) do
    try do
      if is_pid(server) and Process.alive?(server) do
        GenServer.stop(server, :normal)
      end
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @spec run_concurrent(pos_integer(), (integer() -> term()), timeout()) :: [term()]
  def run_concurrent(count, fun, timeout \\ 5000) do
    tasks =
      for i <- 1..count do
        Task.async(fn -> fun.(i) end)
      end

    Task.await_many(tasks, timeout)
  end

  @spec collect_messages(timeout()) :: [term()]
  def collect_messages(timeout_ms \\ 100) do
    collect_messages_acc([], timeout_ms)
  end

  defp collect_messages_acc(acc, timeout_ms) do
    receive do
      msg -> collect_messages_acc([msg | acc], timeout_ms)
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end

  defmacro assert_all_match(results, pattern) do
    quote do
      Enum.each(unquote(results), fn result ->
        assert match?(unquote(pattern), result),
               "Expected #{inspect(result)} to match #{unquote(Macro.to_string(pattern))}"
      end)
    end
  end
end
