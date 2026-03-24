defmodule ASM.ProviderBackend do
  @moduledoc """
  Runtime contract for provider backends.

  Both landed backend lanes satisfy this behaviour:

  - `ASM.ProviderBackend.Core`
  - `ASM.ProviderBackend.SDK`

  Lane selection is owned by `ASM.ProviderRegistry` and remains orthogonal to
  `execution_mode`.
  """

  defmodule Event do
    @moduledoc """
    ASM-owned event delivery envelope emitted by provider backends.
    """

    alias CliSubprocessCore.Event, as: CoreEvent

    @enforce_keys [:subscription_ref, :core_event]
    defstruct [:subscription_ref, :core_event]

    @type t :: %__MODULE__{
            subscription_ref: reference(),
            core_event: CoreEvent.t()
          }

    @spec new(reference(), CoreEvent.t()) :: t()
    def new(subscription_ref, %CoreEvent{} = core_event)
        when is_reference(subscription_ref) do
      %__MODULE__{subscription_ref: subscription_ref, core_event: core_event}
    end
  end

  defmodule Info do
    @moduledoc """
    ASM-owned backend metadata contract consumed by the orchestration kernel.
    """

    @enforce_keys [:provider, :lane, :backend, :runtime]
    defstruct [
      :provider,
      :lane,
      :backend,
      :runtime,
      capabilities: [],
      session: %{pid: nil, details: %{}},
      observability: %{}
    ]

    @type session :: %{
            pid: pid() | nil,
            details: map()
          }

    @type t :: %__MODULE__{
            provider: atom() | nil,
            lane: atom() | nil,
            backend: module(),
            runtime: module(),
            capabilities: [atom()],
            session: session(),
            observability: map()
          }

    @spec new(keyword() | map()) :: t()
    def new(attrs) when is_list(attrs) or is_map(attrs) do
      attrs = Enum.into(attrs, %{})
      provider = Map.get(attrs, :provider)
      lane = Map.get(attrs, :lane)
      backend = Map.fetch!(attrs, :backend)
      runtime = Map.fetch!(attrs, :runtime)
      session_pid = Map.get(attrs, :session_pid)
      session_details = session_details(Map.get(attrs, :raw_info))

      observability =
        %{
          provider: provider,
          lane: lane,
          backend: backend,
          runtime: runtime
        }
        |> Map.merge(normalize_map(Map.get(attrs, :observability)))

      %__MODULE__{
        provider: provider,
        lane: lane,
        backend: backend,
        runtime: runtime,
        capabilities: normalize_capabilities(Map.get(attrs, :capabilities, [])),
        session: %{
          pid: session_pid,
          details: session_details
        },
        observability: observability
      }
    end

    @spec normalize(t() | term(), keyword() | map()) :: t()
    def normalize(info_or_raw, attrs \\ [])

    def normalize(%__MODULE__{} = info, attrs) when is_list(attrs) or is_map(attrs) do
      attrs = Enum.into(attrs, %{})

      capabilities =
        if Map.has_key?(attrs, :capabilities),
          do: normalize_capabilities(Map.get(attrs, :capabilities))

      info
      |> maybe_put(:provider, Map.get(attrs, :provider))
      |> maybe_put(:lane, Map.get(attrs, :lane))
      |> maybe_put(:backend, Map.get(attrs, :backend))
      |> maybe_put(:runtime, Map.get(attrs, :runtime))
      |> maybe_put(:capabilities, capabilities)
      |> maybe_put_session_pid(Map.get(attrs, :session_pid))
      |> merge_observability(Map.get(attrs, :observability, %{}))
    end

    def normalize(raw_info, attrs) when is_list(attrs) or is_map(attrs) do
      attrs = Enum.into(attrs, %{})
      new(Map.put(attrs, :raw_info, raw_info))
    end

    @spec merge_observability(t(), map()) :: t()
    def merge_observability(%__MODULE__{} = info, observability) when is_map(observability) do
      %{info | observability: Map.merge(info.observability, observability)}
    end

    def merge_observability(%__MODULE__{} = info, _observability), do: info

    @spec session_event_tag(term(), atom() | nil) :: atom() | nil
    def session_event_tag(raw_info, fallback \\ nil) do
      case raw_session_details(raw_info) do
        %{} = details ->
          Map.get(details, :session_event_tag) ||
            Map.get(details, "session_event_tag") ||
            fallback

        _other ->
          fallback
      end
    end

    defp session_details(%{} = raw_info) do
      raw_info
      |> raw_session_details()
      |> Map.drop([:session_event_tag, "session_event_tag"])
    end

    defp session_details(nil), do: %{}
    defp session_details(other), do: %{value: other}

    defp raw_session_details(%{} = raw_info) do
      raw_info
      |> unwrap_runtime_info()
      |> normalize_map()
    end

    defp raw_session_details(_raw_info), do: %{}

    defp unwrap_runtime_info(%{info: %{} = info}), do: info
    defp unwrap_runtime_info(%{"info" => %{} = info}), do: info
    defp unwrap_runtime_info(%{} = raw_info), do: raw_info

    defp normalize_map(value) when is_map(value), do: value
    defp normalize_map(_value), do: %{}

    defp normalize_capabilities(values) when is_list(values) do
      Enum.filter(values, &is_atom/1)
    end

    defp normalize_capabilities(_values), do: []

    defp maybe_put(info, _field, nil), do: info
    defp maybe_put(info, field, value), do: Map.put(info, field, value)

    defp maybe_put_session_pid(%__MODULE__{} = info, nil), do: info

    defp maybe_put_session_pid(%__MODULE__{} = info, session_pid) when is_pid(session_pid) do
      put_in(info.session.pid, session_pid)
    end

    defp maybe_put_session_pid(%__MODULE__{} = info, _session_pid), do: info
  end

  @callback start_run(map()) :: {:ok, pid(), Info.t()} | {:error, term()}
  @callback send_input(pid(), iodata(), keyword()) :: :ok | {:error, term()}
  @callback end_input(pid()) :: :ok | {:error, term()}
  @callback interrupt(pid()) :: :ok | {:error, term()}
  @callback close(pid()) :: :ok
  @callback subscribe(pid(), pid(), reference()) :: :ok | {:error, term()}
  @callback info(pid()) :: Info.t()
end
