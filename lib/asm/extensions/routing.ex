defmodule ASM.Extensions.Routing do
  @moduledoc """
  Public routing extension API.

  This domain provides deterministic provider selection with
  health-aware failover, fully owned by extension processes.
  """

  use Boundary,
    deps: [ASM],
    exports: [
      HealthTracker,
      Router,
      Strategy,
      Strategy.Priority,
      Strategy.RoundRobin,
      Strategy.Weighted
    ]

  alias ASM.Extensions.Routing.Router

  @spec start_router(keyword()) :: GenServer.on_start()
  def start_router(opts) when is_list(opts), do: Router.start_link(opts)

  @spec select_provider(pid(), keyword()) ::
          {:ok, Router.selection()} | {:error, ASM.Error.t()}
  def select_provider(router, opts \\ []) when is_list(opts),
    do: Router.select_provider(router, opts)

  @spec report_success(pid(), Router.selection() | Router.provider_id()) ::
          :ok | {:error, ASM.Error.t()}
  def report_success(router, provider_ref), do: Router.report_success(router, provider_ref)

  @spec report_failure(pid(), Router.selection() | Router.provider_id(), term()) ::
          :ok | {:error, ASM.Error.t()}
  def report_failure(router, provider_ref, reason),
    do: Router.report_failure(router, provider_ref, reason)

  @spec report_result(pid(), Router.selection() | Router.provider_id(), term()) ::
          :ok | {:error, ASM.Error.t()}
  def report_result(router, provider_ref, result) do
    case result do
      :ok ->
        report_success(router, provider_ref)

      {:ok, _value} ->
        report_success(router, provider_ref)

      {:error, reason} ->
        report_failure(router, provider_ref, reason)

      other ->
        report_failure(router, provider_ref, {:unexpected_result, other})
    end
  end

  @spec provider_health(pid(), Router.provider_id()) ::
          {:ok, Router.health_status()} | {:error, ASM.Error.t()}
  def provider_health(router, provider_id), do: Router.provider_health(router, provider_id)

  @spec health_snapshot(pid()) :: {:ok, %{Router.provider_id() => Router.health_status()}}
  def health_snapshot(router), do: Router.health_snapshot(router)
end
