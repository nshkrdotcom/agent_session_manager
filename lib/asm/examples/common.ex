defmodule ASM.Examples.Common do
  @moduledoc false

  alias ASM.{Error, Event, Message, Provider, Result}

  @type lane :: :auto | :core | :sdk

  @enforce_keys [:provider, :prompt, :session_opts, :lane]
  defstruct [:provider, :prompt, :session_opts, :lane, :sdk_root]

  @type t :: %__MODULE__{
          provider: Provider.provider_name(),
          prompt: String.t(),
          session_opts: keyword(),
          lane: lane(),
          sdk_root: String.t() | nil
        }

  @providers [:claude, :gemini, :codex, :amp]

  @spec example_config!(String.t(), String.t(), String.t(), keyword()) :: t()
  def example_config!(script_name, description, default_prompt, opts \\ [])
      when is_binary(script_name) and is_binary(description) and is_binary(default_prompt) and
             is_list(opts) do
    case build_example_config(System.argv(), script_name, description, default_prompt, opts) do
      {:ok, %__MODULE__{} = config} ->
        prepare_example!(config)

      {:usage, status, output} ->
        IO.puts(output)
        System.halt(status)
    end
  end

  @spec build_example_config([String.t()], String.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:usage, 0 | 1, String.t()}
  def build_example_config(argv, script_name, description, default_prompt, opts \\ [])
      when is_list(argv) and is_binary(script_name) and is_binary(description) and
             is_binary(default_prompt) and is_list(opts) do
    provider_sdk? = Keyword.get(opts, :provider_sdk?, false)

    {parsed_opts, positional, invalid} =
      normalized_argv(argv)
      |> OptionParser.parse(
        strict: [
          cli_path: :string,
          cwd: :string,
          help: :boolean,
          lane: :string,
          model: :string,
          permission_mode: :string,
          prompt: :string,
          provider: :string,
          sdk_root: :string
        ],
        aliases: [h: :help, p: :provider]
      )

    cond do
      Keyword.get(parsed_opts, :help) ->
        {:usage, 0, usage_text(script_name, description, default_prompt)}

      invalid != [] ->
        {:usage, 1,
         "invalid options: #{inspect(invalid)}\n\n" <>
           usage_text(script_name, description, default_prompt)}

      true ->
        build_resolved_config(
          parsed_opts,
          positional,
          script_name,
          description,
          default_prompt,
          provider_sdk?
        )
    end
  end

  @spec query_opts(t()) :: keyword()
  def query_opts(%__MODULE__{session_opts: session_opts}) do
    Keyword.drop(session_opts, [:provider])
  end

  @spec sdk_bridge_opts(t()) :: keyword()
  def sdk_bridge_opts(%__MODULE__{session_opts: session_opts}) do
    Keyword.drop(session_opts, [:lane])
  end

  @spec start_session!(t()) :: pid()
  def start_session!(%__MODULE__{session_opts: session_opts}) do
    case ASM.start_session(session_opts) do
      {:ok, session} ->
        session

      {:error, %Error{} = error} ->
        fail!("failed to start session: #{Exception.message(error)}")

      {:error, other} ->
        fail!("failed to start session: #{inspect(other)}")
    end
  end

  @spec session_info!(pid()) :: ASM.session_info()
  def session_info!(session) when is_pid(session) do
    case ASM.session_info(session) do
      {:ok, info} ->
        info

      {:error, %Error{} = error} ->
        fail!("failed to read session info: #{Exception.message(error)}")
    end
  end

  @spec query!(pid() | Provider.provider_name(), String.t(), keyword()) :: Result.t()
  def query!(session_or_provider, prompt, opts \\ [])
      when is_binary(prompt) and is_list(opts) do
    case ASM.query(session_or_provider, prompt, opts) do
      {:ok, %Result{} = result} ->
        result

      {:error, %Error{} = error} ->
        fail!("query failed: #{Exception.message(error)}")
    end
  end

  @spec stream_to_result!(pid(), String.t(), keyword()) :: %{
          events: [Event.t()],
          result: Result.t()
        }
  def stream_to_result!(session, prompt, opts \\ [])
      when is_pid(session) and is_binary(prompt) and is_list(opts) do
    {events, printed_delta?} =
      session
      |> ASM.stream(prompt, opts)
      |> Enum.reduce({[], false}, fn %Event{} = event, {events, printed_delta?} ->
        {[event | events], print_stream_event(event) or printed_delta?}
      end)

    events = Enum.reverse(events)
    result = ASM.Stream.final_result(events)

    if printed_delta? do
      IO.puts("")
    end

    if not printed_delta? and is_binary(result.text) and result.text != "" do
      IO.puts(result.text)
    end

    case result.error do
      nil ->
        %{events: events, result: result}

      %Error{} = error ->
        fail!("stream failed: #{Exception.message(error)}")
    end
  end

  @spec print_result_summary(Result.t(), keyword()) :: :ok
  def print_result_summary(%Result{} = result, opts \\ []) do
    label = Keyword.get(opts, :label, "result")
    metadata = result.metadata || %{}

    IO.puts("""
    #{label}_run_id=#{result.run_id}
    #{label}_session_id=#{result.session_id}
    #{label}_requested_lane=#{inspect(Map.get(metadata, :requested_lane))}
    #{label}_preferred_lane=#{inspect(Map.get(metadata, :preferred_lane))}
    #{label}_lane=#{inspect(Map.get(metadata, :lane))}
    #{label}_backend=#{inspect(Map.get(metadata, :backend))}
    #{label}_execution_mode=#{inspect(Map.get(metadata, :execution_mode))}
    #{label}_stop_reason=#{inspect(result.stop_reason)}
    #{label}_duration_ms=#{inspect(result.duration_ms)}
    #{label}_cost=#{inspect(result.cost)}
    #{label}_text=#{inspect(result.text)}
    #{label}_error=#{inspect(result.error)}
    """)

    :ok
  end

  @spec assert_provider!(t(), Provider.provider_name()) :: :ok
  def assert_provider!(%__MODULE__{provider: provider}, expected) when provider == expected,
    do: :ok

  def assert_provider!(%__MODULE__{provider: provider}, expected) do
    fail!("this example requires provider #{inspect(expected)}, got #{inspect(provider)}")
  end

  @spec ensure_provider_sdk_loaded!(Provider.provider_name(), keyword()) :: :ok
  def ensure_provider_sdk_loaded!(provider, opts \\ [])
      when is_atom(provider) and is_list(opts) do
    provider_definition = Provider.resolve!(provider)
    example_support = Provider.example_support!(provider_definition)
    cli_path = Keyword.get(opts, :cli_path)
    sdk_root = Keyword.get(opts, :sdk_root) || default_sdk_root(provider)

    export_sdk_cli_env!(provider, cli_path)

    cond do
      Code.ensure_loaded?(provider_definition.sdk_runtime) ->
        ensure_sdk_application_started!(example_support.sdk_app)

      is_nil(sdk_root) ->
        fail!(
          "provider SDK for #{inspect(provider)} is not on the code path. " <>
            "Add it in a host app or pass --sdk-root /path/to/#{example_support.sdk_repo_dir}."
        )

      true ->
        ensure_sdk_checkout!(provider, sdk_root)
        ensure_sdk_build!(sdk_root, example_support.sdk_app)
        append_sdk_paths!(sdk_root)

        unless Code.ensure_loaded?(provider_definition.sdk_runtime) do
          fail!(
            "loaded code paths from #{sdk_root}, but #{inspect(provider_definition.sdk_runtime)} " <>
              "is still unavailable"
          )
        end

        ensure_sdk_application_started!(example_support.sdk_app)
    end
  end

  defp build_resolved_config(
         parsed_opts,
         positional,
         script_name,
         description,
         default_prompt,
         provider_sdk?
       ) do
    case parse_provider(Keyword.get(parsed_opts, :provider)) do
      :missing ->
        {:usage, 0, no_provider_selected_text(script_name, description, default_prompt)}

      {:error, message} ->
        {:usage, 1, message <> "\n\n" <> usage_text(script_name, description, default_prompt)}

      {:ok, provider} ->
        prompt = resolve_prompt(parsed_opts, positional, default_prompt)

        case parse_lane(Keyword.get(parsed_opts, :lane)) do
          {:ok, lane} ->
            sdk_root = resolve_sdk_root(provider, parsed_opts, lane, provider_sdk?)
            session_opts = build_session_opts(provider, lane, parsed_opts)

            {:ok,
             %__MODULE__{
               provider: provider,
               prompt: prompt,
               session_opts: session_opts,
               lane: lane,
               sdk_root: sdk_root
             }}

          {:error, message} ->
            {:usage, 1, message <> "\n\n" <> usage_text(script_name, description, default_prompt)}
        end
    end
  end

  defp prepare_example!(%__MODULE__{} = config) do
    ensure_cli!(config.provider, config.session_opts)
    maybe_boot_provider_sdk!(config.provider, config.lane, config.sdk_root, config.session_opts)
    ensure_started!()
    config
  end

  defp ensure_started! do
    case Application.ensure_all_started(:agent_session_manager) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        fail!("failed to start :agent_session_manager: #{inspect(reason)}")
    end
  end

  defp normalized_argv(argv) do
    Enum.reject(argv, &(&1 == "--"))
  end

  defp parse_provider(nil), do: :missing

  defp parse_provider(provider_name) when is_binary(provider_name) do
    provider =
      provider_name
      |> String.trim()
      |> String.downcase()

    case provider do
      "amp" -> {:ok, :amp}
      "claude" -> {:ok, :claude}
      "codex" -> {:ok, :codex}
      "gemini" -> {:ok, :gemini}
      _ -> {:error, "unsupported provider #{inspect(provider_name)}"}
    end
  end

  defp resolve_prompt(opts, positional, default_prompt) do
    case Keyword.get(opts, :prompt) || join_prompt(positional) do
      nil -> default_prompt
      "" -> default_prompt
      prompt -> prompt
    end
  end

  defp join_prompt([]), do: nil

  defp join_prompt(positional) do
    positional
    |> Enum.join(" ")
    |> String.trim()
  end

  defp build_session_opts(provider, lane, opts) do
    example_support = Provider.example_support!(provider)
    cli_path = Keyword.get(opts, :cli_path) || System.get_env(example_support.cli_path_env)

    []
    |> Keyword.put(:provider, provider)
    |> Keyword.put(:lane, lane)
    |> put_opt(:cli_path, resolved_cli_path(provider, cli_path))
    |> put_opt(:cwd, Keyword.get(opts, :cwd))
    |> put_opt(:model, Keyword.get(opts, :model) || System.get_env(example_support.model_env))
    |> put_opt(
      :permission_mode,
      Keyword.get(opts, :permission_mode) || System.get_env("ASM_PERMISSION_MODE")
    )
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolved_cli_path(_provider, path) when is_binary(path) and path != "", do: path

  defp resolved_cli_path(provider, _path) do
    provider
    |> Provider.example_support!()
    |> Map.fetch!(:cli_command)
    |> System.find_executable()
  end

  defp ensure_cli!(provider, opts) do
    case cli_check(provider, opts) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        example_support = Provider.example_support!(provider)

        IO.puts("""
        CLI resolution failed for #{inspect(provider)}.
        #{Exception.message(error)}
        Install hint: #{example_support.install_hint}
        """)

        System.halt(1)
    end
  end

  defp cli_check(provider, opts) do
    with {:ok, %Provider{name: resolved_provider}} <- Provider.resolve(provider),
         :ok <- ensure_executable(resolved_provider, Keyword.get(opts, :cli_path)) do
      :ok
    end
  end

  defp ensure_executable(_provider, path) when is_binary(path) and path != "" do
    if File.exists?(path) do
      :ok
    else
      {:error, Error.new(:cli_not_found, :provider, "CLI executable not found at #{path}")}
    end
  end

  defp ensure_executable(provider, _path) do
    command =
      provider
      |> Provider.example_support!()
      |> Map.fetch!(:cli_command)

    if System.find_executable(command) do
      :ok
    else
      {:error,
       Error.new(
         :cli_not_found,
         :provider,
         "CLI executable #{inspect(command)} not found on PATH"
       )}
    end
  end

  defp parse_lane(nil), do: {:ok, :core}

  defp parse_lane(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "auto" -> {:ok, :auto}
      "core" -> {:ok, :core}
      "sdk" -> {:ok, :sdk}
      other -> {:error, "unsupported lane #{inspect(other)}; expected auto, core, or sdk"}
    end
  end

  defp maybe_boot_provider_sdk!(_provider, :core, _sdk_root, _session_opts), do: :ok

  defp maybe_boot_provider_sdk!(provider, :sdk, sdk_root, session_opts) do
    ensure_provider_sdk_loaded!(provider,
      sdk_root: sdk_root,
      cli_path: Keyword.get(session_opts, :cli_path)
    )
  end

  defp maybe_boot_provider_sdk!(provider, :auto, sdk_root, session_opts) do
    if sdk_root || provider_sdk_loaded?(provider) do
      ensure_provider_sdk_loaded!(provider,
        sdk_root: sdk_root,
        cli_path: Keyword.get(session_opts, :cli_path)
      )
    else
      :ok
    end
  end

  defp provider_sdk_loaded?(provider) do
    provider
    |> Provider.resolve!()
    |> Map.fetch!(:sdk_runtime)
    |> Code.ensure_loaded?()
  end

  defp resolve_sdk_root(provider, opts, lane, provider_sdk?) do
    case Keyword.get(opts, :sdk_root) do
      nil ->
        resolve_default_sdk_root(provider, lane, provider_sdk?)

      "" ->
        resolve_default_sdk_root(provider, lane, provider_sdk?)

      path ->
        Path.expand(path)
    end
  end

  defp resolve_default_sdk_root(_provider, :core, false), do: nil

  defp resolve_default_sdk_root(provider, _lane, _provider_sdk?) do
    provider_sdk_root_env(provider) || default_sdk_root(provider)
  end

  defp provider_sdk_root_env(provider) do
    provider
    |> Provider.example_support!()
    |> Map.fetch!(:sdk_root_env)
    |> System.get_env()
    |> case do
      nil -> nil
      "" -> nil
      path -> Path.expand(path)
    end
  end

  defp default_sdk_root(provider) do
    repo_root = project_root()

    repo_dir =
      provider
      |> Provider.example_support!()
      |> Map.fetch!(:sdk_repo_dir)

    path = Path.expand("../#{repo_dir}", repo_root)

    if File.dir?(path), do: path, else: nil
  end

  defp project_root do
    case Mix.Project.project_file() do
      nil -> Path.expand("../../..", __DIR__)
      project_file -> project_file |> Path.dirname() |> Path.expand()
    end
  end

  defp ensure_sdk_checkout!(provider, sdk_root) do
    example_support = Provider.example_support!(provider)
    mix_file = Path.join(sdk_root, "mix.exs")

    unless File.regular?(mix_file) do
      fail!(
        "provider SDK root #{inspect(sdk_root)} is not a valid #{example_support.sdk_repo_dir} checkout"
      )
    end
  end

  defp ensure_sdk_build!(sdk_root, app) do
    ebin_dir = Path.join([sdk_root, "_build", "dev", "lib", Atom.to_string(app), "ebin"])

    unless File.dir?(ebin_dir) do
      run_mix!(sdk_root, ["deps.get"])
      run_mix!(sdk_root, ["compile"])
    end
  end

  defp append_sdk_paths!(sdk_root) do
    sdk_root
    |> Path.join("_build/dev/lib/*/ebin")
    |> Path.wildcard()
    |> Enum.sort()
    |> Code.append_paths()
  end

  defp ensure_sdk_application_started!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> fail!("failed to start #{inspect(app)}: #{inspect(reason)}")
    end
  end

  defp export_sdk_cli_env!(provider, cli_path) when is_binary(cli_path) and cli_path != "" do
    case Provider.example_support!(provider).sdk_cli_env do
      nil -> :ok
      env_name -> System.put_env(env_name, cli_path)
    end
  end

  defp export_sdk_cli_env!(_provider, _cli_path), do: :ok

  defp run_mix!(sdk_root, args) when is_list(args) do
    case System.cmd("mix", args, cd: sdk_root, stderr_to_stdout: true) do
      {output, 0} ->
        if String.trim(output) != "" do
          IO.write(output)
        end

        :ok

      {output, status} ->
        fail!(
          "mix #{Enum.join(args, " ")} failed in #{sdk_root} with status #{status}\n#{output}"
        )
    end
  end

  defp print_stream_event(%Event{} = event) do
    case Event.text_delta(event) do
      text when is_binary(text) and text != "" ->
        IO.write(text)
        true

      _other ->
        case Event.legacy_payload(event) do
          %Message.Error{kind: kind, message: message} ->
            IO.puts("error_event kind=#{inspect(kind)} message=#{inspect(message)}")
            false

          _payload ->
            false
        end
    end
  end

  defp no_provider_selected_text(script_name, description, default_prompt) do
    """
    #{script_name} did not run because no provider was selected.
    #{description}

    Choose one provider with `--provider claude|gemini|codex|amp`.
    Example:
      mix run --no-start examples/#{script_name} -- --provider claude

    Default prompt:
      #{default_prompt}
    """
  end

  defp usage_text(script_name, description, default_prompt) do
    provider_env_lines =
      @providers
      |> Enum.map(fn provider ->
        example_support = Provider.example_support!(provider)
        "#{provider} -> #{example_support.cli_path_env}, #{example_support.model_env}"
      end)
      |> Enum.join("\n  ")

    """
    #{script_name}
    #{description}

    Usage:
      mix run --no-start examples/#{script_name} -- --provider claude
      mix run --no-start examples/#{script_name} -- --provider codex --prompt "Reply with exactly: OK"
      mix run --no-start examples/#{script_name} -- --provider amp --lane sdk --sdk-root ../amp_sdk

    Flags:
      --provider <name>         Required. One of #{Enum.join(@providers, ", ")}.
      --lane <name>             Optional. One of core, auto, sdk. Defaults to core.
      --prompt <text>           Optional. Defaults to the built-in prompt below.
      --model <name>            Optional. Overrides the provider model env var.
      --cli-path <path>         Optional. Overrides the provider CLI path env var.
      --permission-mode <mode>  Optional. Defaults to ASM_PERMISSION_MODE when set.
      --cwd <path>              Optional. Runs the provider from a specific working directory.
      --sdk-root <path>         Optional. Loads a sibling provider SDK checkout for sdk-lane or provider-native examples.
      --help                    Print this message.

    Default prompt:
      #{default_prompt}

    Provider environment:
      #{provider_env_lines}
    """
  end

  defp fail!(message) do
    IO.puts(message)
    System.halt(1)
  end
end
