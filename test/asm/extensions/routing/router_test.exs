defmodule ASM.Extensions.Routing.RouterTest do
  use ASM.TestCase

  alias ASM.Extensions.Routing

  test "select_provider/2 is deterministic with round-robin strategy" do
    assert {:ok, router} = Routing.start_router(providers: [:claude, :gemini, :codex])
    on_exit(fn -> if Process.alive?(router), do: GenServer.stop(router) end)

    assert {:ok, %{provider: :claude}} = Routing.select_provider(router)
    assert {:ok, %{provider: :gemini}} = Routing.select_provider(router)
    assert {:ok, %{provider: :codex_exec}} = Routing.select_provider(router)
    assert {:ok, %{provider: :claude}} = Routing.select_provider(router)
  end

  test "report_failure/3 temporarily excludes provider and next selection fails over" do
    assert {:ok, router} =
             Routing.start_router(providers: [:claude, :gemini], failure_cooldown_ms: 500)

    on_exit(fn -> if Process.alive?(router), do: GenServer.stop(router) end)

    assert {:ok, first} = Routing.select_provider(router)
    assert first.provider == :claude
    assert :ok = Routing.report_failure(router, first, :cli_not_found)

    assert {:ok, %{provider: :gemini}} = Routing.select_provider(router)

    assert {:ok, health} = Routing.provider_health(router, first.id)
    assert health.status == :unhealthy
    assert health.excluded? == true
    assert health.failures == 1
  end

  test "health transitions from unhealthy to degraded after cooldown and healthy on success" do
    {:ok, clock_owner} = Agent.start_link(fn -> 1_000 end)
    on_exit(fn -> if Process.alive?(clock_owner), do: Agent.stop(clock_owner) end)

    clock = fn -> Agent.get(clock_owner, & &1) end

    assert {:ok, router} =
             Routing.start_router(
               providers: [:claude, :gemini],
               failure_cooldown_ms: 100,
               clock: clock
             )

    on_exit(fn -> if Process.alive?(router), do: GenServer.stop(router) end)

    assert {:ok, first} = Routing.select_provider(router)
    assert :ok = Routing.report_failure(router, first, :timeout)

    assert {:ok, unhealthy} = Routing.provider_health(router, first.id)
    assert unhealthy.status == :unhealthy
    assert unhealthy.excluded? == true

    Agent.update(clock_owner, &(&1 + 101))

    assert {:ok, degraded} = Routing.provider_health(router, first.id)
    assert degraded.status == :degraded
    assert degraded.excluded? == false

    assert :ok = Routing.report_success(router, first)

    assert {:ok, recovered} = Routing.provider_health(router, first.id)
    assert recovered.status == :healthy
    assert recovered.excluded? == false
    assert recovered.failures == 0
  end
end
