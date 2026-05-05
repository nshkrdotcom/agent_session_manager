defmodule ASM.ProviderBackend.ProxyTest do
  use ASM.TestCase

  alias ASM.ProviderBackend.Proxy

  defmodule Runtime do
    @moduledoc false

    def session_event_tag, do: :asm_proxy_test_event

    def send_input(_session, _input, _opts), do: :ok
    def end_input(_session), do: :ok
    def interrupt(_session), do: :ok
    def subscribe(_session, _pid, _ref), do: :ok

    def close(session) when is_pid(session) do
      if Process.alive?(session), do: Process.exit(session, :normal)
      :ok
    catch
      :exit, _reason -> :ok
    end

    def info(session) when is_pid(session) do
      %{session_event_tag: session_event_tag(), session: session}
    end
  end

  test "remote noproc session monitor shutdown is a normal proxy lifecycle exit" do
    caller = self()

    {:ok, proxy, _info} =
      Proxy.start_link(
        starter: fn _subscriber ->
          session =
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

          send(caller, {:session, session})
          {:ok, session, Runtime.info(session)}
        end,
        runtime_api: Runtime,
        runtime: Runtime,
        provider: :codex,
        lane: :core,
        backend: ASM.ProviderBackend.Core
      )

    assert_receive {:session, session}

    proxy_ref = Process.monitor(proxy)
    Process.exit(session, :noproc)

    assert_receive {:DOWN, ^proxy_ref, :process, ^proxy, :normal}
  end
end
