defmodule ASM do
  @moduledoc """
  Public facade for the ASM session runtime.
  """

  use Boundary,
    deps: [],
    exports: [
      Content,
      {Content, []},
      Control,
      AdapterSelectionPolicy,
      {Control, []},
      Error,
      Event,
      History,
      HostTool,
      {HostTool, []},
      InferenceEndpoint,
      Message,
      {Message, []},
      Migration.MainCompat,
      Options,
      Pipeline.Plug,
      Permission,
      Provider,
      ProviderBackend,
      ProviderRegistry,
      Result,
      SessionControl,
      Store,
      {Store, []},
      Stream,
      Telemetry
    ]

  alias ASM.{Error, Result, Session, SessionControl, Stream}

  @type session_ref :: GenServer.server()
  @type session_info :: %{
          session_id: String.t(),
          provider: ASM.Provider.provider_name(),
          options: keyword(),
          status: atom()
        }

  @spec start_link(keyword()) :: {:ok, session_ref()} | {:error, Error.t() | term()}
  def start_link(opts \\ []), do: start_session(opts)

  @spec start_session(keyword()) :: {:ok, session_ref()} | {:error, Error.t() | term()}
  def start_session(opts \\ []) do
    session_id = Keyword.get_lazy(opts, :session_id, &ASM.Event.generate_id/0)
    opts = Keyword.put(opts, :session_id, session_id)

    case Session.Supervisor.start_session(opts) do
      {:ok, _subtree_pid} -> lookup_session_server(session_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop_session(String.t() | pid()) :: :ok | {:error, :not_found}
  def stop_session(session_ref)

  def stop_session(session_ref) when is_binary(session_ref) do
    Session.Supervisor.stop_session(session_ref)
  end

  def stop_session(session_ref) when is_pid(session_ref) do
    case session_id(session_ref) do
      nil -> Session.Supervisor.stop_session(session_ref)
      session_id -> Session.Supervisor.stop_session(session_id)
    end
  end

  @spec stream(session_ref(), String.t(), keyword()) :: Enumerable.t()
  def stream(session, prompt, opts \\ []) when is_binary(prompt) do
    Stream.create(session, prompt, opts)
  end

  @spec query(session_ref() | atom(), String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def query(session_or_provider, prompt, opts \\ [])

  def query(session, prompt, opts) when is_pid(session) and is_binary(prompt) do
    result =
      session
      |> stream(prompt, opts)
      |> Stream.final_result()

    case result.error do
      nil ->
        {:ok, result}

      %Error{} = error ->
        {:error, error}
    end
  rescue
    error in [Error] ->
      {:error, error}

    error ->
      {:error, Error.new(:runtime, :runtime, Exception.message(error), cause: error)}
  end

  def query(provider, prompt, opts) when is_atom(provider) and is_binary(prompt) do
    case start_session(Keyword.put(opts, :provider, provider)) do
      {:ok, session} ->
        run_opts = Keyword.drop(opts, [:session_id, :provider, :name, :options])

        result =
          try do
            query(session, prompt, run_opts)
          after
            _ = stop_session(session)
          end

        case result do
          {:ok, %Result{} = value} ->
            {:ok, value}

          {:error, %Error{} = error} ->
            {:error, error}
        end

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, other} ->
        {:error, Error.new(:runtime, :runtime, inspect(other), cause: other)}
    end
  end

  @spec session_id(session_ref()) :: String.t() | nil
  def session_id(session) do
    Session.Server.get_state(session).session_id
  rescue
    _ -> nil
  end

  @spec session_info(session_ref()) :: {:ok, session_info()} | {:error, Error.t()}
  def session_info(session) do
    state = Session.Server.get_state(session)

    {:ok,
     %{
       session_id: state.session_id,
       provider: state.provider.name,
       options: state.options,
       status: state.status
     }}
  rescue
    error ->
      {:error, Error.new(:runtime, :runtime, "unable to read ASM session info", cause: error)}
  end

  @spec health(session_ref()) :: :healthy | :degraded | {:unhealthy, term()}
  def health(session) when is_pid(session) do
    if Process.alive?(session), do: :healthy, else: {:unhealthy, :not_alive}
  end

  def health(session_id) when is_binary(session_id) do
    case Registry.lookup(:asm_sessions, {session_id, :server}) do
      [{pid, _}] when is_pid(pid) -> health(pid)
      [] -> {:unhealthy, :not_found}
    end
  end

  @spec cost(session_ref()) :: map()
  def cost(session) do
    Session.Server.get_state(session).cost
  end

  @spec interrupt(session_ref(), String.t()) :: :ok | {:error, Error.t()}
  def interrupt(session, run_id), do: Session.Server.cancel_run(session, run_id)

  @spec pause(session_ref(), String.t()) :: :ok | {:error, Error.t()}
  def pause(session, run_id), do: SessionControl.pause(session, run_id)

  @spec checkpoint(session_ref()) :: {:ok, map() | nil} | {:error, Error.t()}
  def checkpoint(session), do: SessionControl.checkpoint(session)

  @spec resume_run(session_ref(), String.t(), keyword()) ::
          {:ok, String.t(), pid() | :queued} | {:error, Error.t()}
  def resume_run(session, prompt, opts \\ []),
    do: SessionControl.resume_run(session, prompt, opts)

  @spec intervene(session_ref(), String.t(), String.t(), keyword()) ::
          {:ok, String.t(), pid() | :queued} | {:error, Error.t()}
  def intervene(session, run_id, prompt, opts \\ []),
    do: SessionControl.intervene(session, run_id, prompt, opts)

  @spec list_provider_sessions(session_ref() | atom(), keyword()) ::
          {:ok, [SessionControl.Entry.t()]} | {:error, Error.t()}
  def list_provider_sessions(provider_or_session, opts \\ []),
    do: SessionControl.list_provider_sessions(provider_or_session, opts)

  @spec approve(session_ref(), String.t(), :allow | :deny) :: :ok | {:error, Error.t()}
  def approve(session, approval_id, decision),
    do: Session.Server.resolve_approval(session, approval_id, decision)

  defp lookup_session_server(session_id) do
    case Registry.lookup(:asm_sessions, {session_id, :server}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        {:error, Error.new(:runtime, :runtime, "Session server not found")}
    end
  end
end
