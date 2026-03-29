defmodule ASM.Examples.Common do
  @moduledoc false

  alias ASM.{Error, Event, Message, Options, Provider, ProviderFeatures, Result}
  alias CliSubprocessCore.ProviderCLI.Error, as: CoreProviderCLIError

  @type lane :: :auto | :core | :sdk

  @enforce_keys [:provider, :prompt, :session_opts, :provider_opts, :lane, :permission_source]
  defstruct [
    :provider,
    :prompt,
    :session_opts,
    :provider_opts,
    :lane,
    :sdk_root,
    :permission_source
  ]

  @type t :: %__MODULE__{
          provider: Provider.provider_name(),
          prompt: String.t(),
          session_opts: keyword(),
          provider_opts: keyword(),
          lane: lane(),
          sdk_root: String.t() | nil,
          permission_source: :cli_flag | :env | :example_default_bypass
        }

  @providers [:claude, :gemini, :codex, :amp]
  @cli_probe_prompt "__ASM_EXAMPLE_CLI_PREFLIGHT__"

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
    provider_opts_builder = Keyword.get(opts, :provider_opts_builder, &build_provider_opts/2)

    {parsed_opts, positional, invalid} =
      normalized_argv(argv)
      |> OptionParser.parse(
        strict: [
          cli_path: :string,
          cwd: :string,
          help: :boolean,
          lane: :string,
          model: :string,
          ollama: :boolean,
          ollama_base_url: :string,
          ollama_http: :boolean,
          ollama_model: :string,
          ollama_timeout_ms: :integer,
          permission_mode: :string,
          prompt: :string,
          provider: :string,
          sdk_root: :string,
          ssh_host: :string,
          ssh_identity_file: :string,
          ssh_port: :integer,
          ssh_user: :string
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
          provider_sdk?,
          provider_opts_builder
        )
    end
  end

  @spec query_opts(t()) :: keyword()
  def query_opts(%__MODULE__{session_opts: session_opts}) do
    Keyword.drop(session_opts, [:provider])
  end

  @spec exact_text_match?(String.t() | nil, String.t()) :: boolean()
  def exact_text_match?(actual, expected)
      when (is_binary(actual) or is_nil(actual)) and is_binary(expected) do
    normalize_exact_text(actual) == normalize_exact_text(expected)
  end

  @spec assert_exact_text!(String.t() | nil, String.t(), keyword()) :: :ok
  def assert_exact_text!(actual, expected, opts \\ [])
      when (is_binary(actual) or is_nil(actual)) and is_binary(expected) and is_list(opts) do
    label = Keyword.get(opts, :label, "result text")

    if exact_text_match?(actual, expected) do
      :ok
    else
      fail!("#{label} mismatch: expected exactly #{inspect(expected)}, got #{inspect(actual)}")
    end
  end

  @spec assert_result_text!(Result.t(), String.t(), keyword()) :: :ok
  def assert_result_text!(%Result{text: text}, expected, opts \\ [])
      when is_binary(expected) and is_list(opts) do
    label = Keyword.get(opts, :label, "result text")
    assert_exact_text!(text, expected, label: label)
  end

  @doc false
  @spec exact_output_smoke_target?(t()) :: boolean()
  def exact_output_smoke_target?(%__MODULE__{} = config) do
    is_nil(exact_output_smoke_skip_reason(config))
  end

  @doc false
  @spec exact_output_smoke_skip_reason(t()) :: String.t() | nil
  def exact_output_smoke_skip_reason(%__MODULE__{} = config) do
    case exact_output_smoke_policy(config) do
      :assert -> nil
      {:skip, reason} -> reason
    end
  end

  @spec assert_result_text_for_smoke!(t(), Result.t(), String.t(), keyword()) :: :ok
  def assert_result_text_for_smoke!(
        %__MODULE__{} = config,
        %Result{text: text},
        expected,
        opts \\ []
      )
      when is_binary(expected) and is_list(opts) do
    label = Keyword.get(opts, :label, "result text")

    case exact_output_smoke_skip_reason(config) do
      nil ->
        assert_exact_text!(text, expected, label: label)

      reason ->
        print_smoke_skip_notice(label, reason)
    end
  end

  @spec resolve_model_payload!(Provider.provider_name(), keyword()) ::
          CliSubprocessCore.ModelRegistry.selection()
  def resolve_model_payload!(provider, provider_opts)
      when is_atom(provider) and is_list(provider_opts) do
    case Options.resolve_model_payload(provider, provider_opts) do
      {:ok, payload} ->
        payload

      {:error, %Error{} = error} ->
        fail!("model resolution failed: #{Exception.message(error)}")
    end
  end

  @spec sdk_bridge_opts(t()) :: keyword()
  def sdk_bridge_opts(%__MODULE__{provider_opts: provider_opts}) do
    provider_opts
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
    {events, printed_delta?} = collect_stream_events(session, prompt, opts)
    result = ASM.Stream.final_result(events)

    maybe_print_stream_result(result, printed_delta?)
    finalize_stream_result!(events, result)
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
         provider_sdk?,
         provider_opts_builder
       ) do
    case parse_provider(Keyword.get(parsed_opts, :provider)) do
      :missing ->
        {:usage, 0, no_provider_selected_text(script_name, description, default_prompt)}

      {:error, message} ->
        {:usage, 1, message <> "\n\n" <> usage_text(script_name, description, default_prompt)}

      {:ok, provider} ->
        prompt = resolve_prompt(parsed_opts, positional, default_prompt)

        build_lane_resolved_config(
          provider,
          parsed_opts,
          prompt,
          script_name,
          description,
          default_prompt,
          provider_sdk?,
          provider_opts_builder
        )
    end
  end

  defp build_lane_resolved_config(
         provider,
         parsed_opts,
         prompt,
         script_name,
         description,
         default_prompt,
         provider_sdk?,
         provider_opts_builder
       ) do
    usage = usage_text(script_name, description, default_prompt)

    case parse_lane(Keyword.get(parsed_opts, :lane)) do
      {:ok, lane} ->
        sdk_root = resolve_sdk_root(provider, parsed_opts, lane, provider_sdk?)

        case build_session_opts(provider, lane, parsed_opts) do
          {:ok, {session_opts, permission_source}} ->
            build_provider_config(
              provider,
              prompt,
              lane,
              sdk_root,
              session_opts,
              permission_source,
              usage,
              provider_opts_builder
            )

          {:error, message} ->
            {:usage, 1, message <> "\n\n" <> usage}
        end

      {:error, message} ->
        {:usage, 1, message <> "\n\n" <> usage}
    end
  end

  defp build_provider_config(
         provider,
         prompt,
         lane,
         sdk_root,
         session_opts,
         permission_source,
         usage,
         provider_opts_builder
       ) do
    case provider_opts_builder.(provider, session_opts) do
      {:ok, provider_opts} ->
        {:ok,
         %__MODULE__{
           provider: provider,
           prompt: prompt,
           session_opts: session_opts,
           provider_opts: provider_opts,
           lane: lane,
           sdk_root: sdk_root,
           permission_source: permission_source
         }}

      {:error, %Error{} = error} ->
        {:usage, 1, Exception.message(error) <> "\n\n" <> usage}
    end
  end

  defp prepare_example!(%__MODULE__{} = config) do
    print_runtime_notice(config)
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
    cli_path = Keyword.get(opts, :cli_path)
    {permission_mode, permission_source} = resolve_permission_mode(opts)

    with {:ok, execution_surface} <- build_execution_surface(opts) do
      session_opts =
        []
        |> Keyword.put(:provider, provider)
        |> Keyword.put(:lane, lane)
        |> put_opt(:cli_path, cli_path)
        |> put_opt(:cwd, Keyword.get(opts, :cwd))
        |> put_opt(:execution_surface, execution_surface)
        |> put_opt(
          :model,
          Keyword.get(opts, :model) ||
            System.get_env(example_support.model_env) ||
            example_support.example_default_model
        )
        |> put_opt(:permission_mode, permission_mode)
        |> put_opt(:ollama, Keyword.get(opts, :ollama))
        |> put_opt(:ollama_model, Keyword.get(opts, :ollama_model))
        |> put_opt(:ollama_base_url, Keyword.get(opts, :ollama_base_url))
        |> put_opt(:ollama_http, Keyword.get(opts, :ollama_http))
        |> put_opt(:ollama_timeout_ms, Keyword.get(opts, :ollama_timeout_ms))

      {:ok, {session_opts, permission_source}}
    end
  end

  defp resolve_permission_mode(opts) when is_list(opts) do
    cond do
      present_option?(Keyword.get(opts, :permission_mode)) ->
        {Keyword.get(opts, :permission_mode), :cli_flag}

      present_option?(System.get_env("ASM_PERMISSION_MODE")) ->
        {System.get_env("ASM_PERMISSION_MODE"), :env}

      true ->
        {:bypass, :example_default_bypass}
    end
  end

  defp present_option?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_option?(nil), do: false
  defp present_option?(_value), do: true

  defp build_execution_surface(opts) when is_list(opts) do
    ssh_host = Keyword.get(opts, :ssh_host)
    ssh_user = Keyword.get(opts, :ssh_user)
    ssh_port = Keyword.get(opts, :ssh_port)
    ssh_identity_file = Keyword.get(opts, :ssh_identity_file)

    cond do
      not present_option?(ssh_host) and
          Enum.any?([ssh_user, ssh_port, ssh_identity_file], &present_option?/1) ->
        {:error, "SSH example flags require --ssh-host when any other --ssh-* flag is set."}

      not present_option?(ssh_host) ->
        {:ok, nil}

      true ->
        with {:ok, {destination, parsed_user}} <- split_ssh_host(ssh_host),
             {:ok, effective_user} <- coalesce_ssh_user(parsed_user, ssh_user),
             {:ok, identity_file} <- normalize_identity_file(ssh_identity_file),
             transport_options <-
               []
               |> Keyword.put(:destination, destination)
               |> put_opt(:ssh_user, effective_user)
               |> put_opt(:port, ssh_port)
               |> put_opt(:identity_file, identity_file),
             {:ok, execution_surface} <-
               CliSubprocessCore.ExecutionSurface.new(
                 surface_kind: :ssh_exec,
                 transport_options: transport_options
               ) do
          {:ok, execution_surface}
        else
          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, "invalid SSH example flags: #{inspect(reason)}"}
        end
    end
  end

  defp split_ssh_host(ssh_host) when is_binary(ssh_host) do
    case String.trim(ssh_host) do
      "" ->
        {:error, "--ssh-host must be a non-empty host name"}

      trimmed ->
        case String.split(trimmed, "@", parts: 2) do
          [destination] ->
            {:ok, {destination, nil}}

          [inline_user, destination] when inline_user != "" and destination != "" ->
            {:ok, {destination, inline_user}}

          _other ->
            {:error, "--ssh-host must be either <host> or <user>@<host>"}
        end
    end
  end

  defp coalesce_ssh_user(nil, nil), do: {:ok, nil}

  defp coalesce_ssh_user(inline_user, nil), do: {:ok, inline_user}

  defp coalesce_ssh_user(nil, ssh_user) when is_binary(ssh_user) do
    case String.trim(ssh_user) do
      "" -> {:error, "--ssh-user must be a non-empty string"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp coalesce_ssh_user(inline_user, ssh_user) when is_binary(ssh_user) do
    normalized = String.trim(ssh_user)

    cond do
      normalized == "" ->
        {:error, "--ssh-user must be a non-empty string"}

      normalized == inline_user ->
        {:ok, inline_user}

      true ->
        {:error,
         "--ssh-host already contains #{inspect(inline_user)}; omit --ssh-user or make it match"}
    end
  end

  defp normalize_identity_file(nil), do: {:ok, nil}

  defp normalize_identity_file(path) when is_binary(path) do
    case String.trim(path) do
      "" -> {:error, "--ssh-identity-file must be a non-empty path"}
      trimmed -> {:ok, Path.expand(trimmed)}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_cli!(provider, opts) do
    case cli_check(provider, opts) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        IO.puts("""
        CLI resolution failed for #{inspect(provider)}.
        #{Exception.message(error)}
        """)

        System.halt(1)
    end
  end

  defp build_provider_opts(provider, session_opts) do
    provider_schema = Provider.resolve!(provider).options_schema

    session_opts
    |> Keyword.drop([:lane, :execution_surface])
    |> Options.validate(provider_schema)
    |> case do
      {:ok, validated} ->
        Options.finalize_provider_opts(provider, Keyword.delete(validated, :provider))

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp cli_check(provider, opts) do
    with {:ok, %Provider{} = resolved_provider} <- Provider.resolve(provider),
         {:ok, _invocation} <-
           resolved_provider.core_profile.build_invocation(cli_probe_opts(opts)) do
      :ok
    else
      {:error, %CoreProviderCLIError{} = error} ->
        {:error,
         Error.new(
           :cli_not_found,
           :provider,
           Exception.message(error),
           cause: error.cause,
           provider: provider
         )}

      {:error, reason} ->
        {:error,
         Error.new(
           :config_invalid,
           :provider,
           "CLI preflight failed: #{inspect(reason)}",
           cause: reason,
           provider: provider
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

  defp collect_stream_events(session, prompt, opts) do
    session
    |> ASM.stream(prompt, opts)
    |> Enum.reduce({[], false}, fn %Event{} = event, {events, printed_delta?} ->
      next_printed_delta? = print_stream_event(event) or printed_delta?
      {[event | events], next_printed_delta?}
    end)
    |> then(fn {events, printed_delta?} -> {Enum.reverse(events), printed_delta?} end)
  end

  defp cli_probe_opts(opts) do
    []
    |> Keyword.put(:prompt, @cli_probe_prompt)
    |> put_opt(:command, Keyword.get(opts, :cli_path))
    |> put_opt(:execution_surface, Keyword.get(opts, :execution_surface))
  end

  defp print_runtime_notice(%__MODULE__{
         provider: provider,
         provider_opts: provider_opts,
         lane: lane,
         permission_source: permission_source
       }) do
    permission =
      ProviderFeatures.permission_mode!(provider, provider_opts[:provider_permission_mode])

    IO.puts("""
    notice_provider=#{provider}
    notice_lane=#{lane}
    notice_permission_mode=#{inspect(provider_opts[:permission_mode])}
    notice_permission_source=#{permission_source}
    notice_native_permission_mode=#{inspect(permission.native_mode)}
    notice_native_permission_cli=#{inspect(permission.cli_excerpt)}
    """)

    if ollama_enabled?(provider_opts) do
      ollama = ProviderFeatures.common_feature!(provider, :ollama)
      model_payload = resolve_model_payload!(provider, provider_opts)
      support_tier = payload_support_tier(model_payload)

      IO.puts("""
      notice_ollama=true
      notice_ollama_activation=#{inspect(ollama.activation)}
      notice_ollama_model_strategy=#{inspect(ollama.model_strategy)}
      notice_ollama_resolved_model=#{inspect(payload_value(model_payload, :resolved_model))}
      notice_ollama_support_tier=#{inspect(support_tier)}
      """)
    end
  end

  defp maybe_print_stream_result(%Result{text: text}, printed_delta?) do
    if printed_delta? do
      IO.puts("")
    end

    if not printed_delta? and is_binary(text) and text != "" do
      IO.puts(text)
    end
  end

  defp finalize_stream_result!(events, %Result{error: nil} = result) do
    %{events: events, result: result}
  end

  defp finalize_stream_result!(_events, %Result{error: %Error{} = error}) do
    fail!("stream failed: #{Exception.message(error)}")
  end

  defp normalize_exact_text(text) when is_binary(text), do: String.trim(text)
  defp normalize_exact_text(nil), do: nil

  defp exact_output_smoke_policy(%__MODULE__{provider: :codex, provider_opts: provider_opts}) do
    case Keyword.get(provider_opts, :model_payload) do
      payload when is_map(payload) ->
        support_tier = payload_support_tier(payload)
        resolved_model = payload_value(payload, :resolved_model)

        if payload_backend_metadata(payload)["oss_provider"] == "ollama" and
             support_tier == "runtime_validated_only" do
          {:skip,
           "Codex/Ollama model #{inspect(resolved_model)} is support_tier=#{inspect(support_tier)}; " <>
             "exact-output smoke assertions only gate validated_default models."}
        else
          :assert
        end

      _other ->
        :assert
    end
  end

  defp exact_output_smoke_policy(%__MODULE__{}), do: :assert

  defp print_smoke_skip_notice(label, reason) when is_binary(label) and is_binary(reason) do
    key = smoke_assertion_key(label)

    IO.puts("""
    #{key}_exact_assertion=:skipped
    #{key}_exact_assertion_reason=#{inspect(reason)}
    """)

    :ok
  end

  defp smoke_assertion_key(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "result"
      normalized -> normalized
    end
  end

  defp payload_support_tier(payload) when is_map(payload) do
    payload
    |> payload_backend_metadata()
    |> Map.get("support_tier")
  end

  defp ollama_enabled?(provider_opts) when is_list(provider_opts) do
    case Keyword.get(provider_opts, :model_payload) do
      payload when is_map(payload) ->
        payload_backend_metadata(payload)["oss_provider"] == "ollama" or
          payload_value(payload, :provider_backend) in [:ollama, "ollama"]

      _other ->
        Keyword.get(provider_opts, :ollama, false)
    end
  end

  defp payload_value(payload, key) when is_map(payload) and is_atom(key) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
  end

  defp payload_backend_metadata(payload) when is_map(payload) do
    payload
    |> Map.get(:backend_metadata, Map.get(payload, "backend_metadata", %{}))
    |> case do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
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
      Enum.map_join(@providers, "\n  ", fn provider ->
        example_support = Provider.example_support!(provider)
        "#{provider} -> #{example_support.cli_path_env}, #{example_support.model_env}"
      end)

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
      --cli-path <path|command> Optional. Overrides the provider CLI env var and launcher.
      --permission-mode <mode>  Optional. Defaults to ASM_PERMISSION_MODE when set, otherwise the examples force bypass mode.
      --ollama                  Optional. Enables ASM's common Ollama surface when the provider supports it.
      --ollama-model <name>     Optional. Sets the direct Ollama model id for the common Ollama surface.
      --ollama-base-url <url>   Optional. Overrides the Ollama base URL for the common Ollama surface.
      --ollama-http             Optional. Enables plain HTTP for the common Ollama surface when supported.
      --ollama-timeout-ms <ms>  Optional. Sets the Ollama timeout when supported.
      --cwd <path>              Optional. Runs the provider from a specific working directory.
      --sdk-root <path>         Optional. Loads a sibling provider SDK checkout for sdk-lane or provider-native examples.
      --ssh-host <host>         Optional. Runs the example over execution_surface=:ssh_exec.
      --ssh-user <user>         Optional. SSH user override for --ssh-host.
      --ssh-port <port>         Optional. SSH port override for --ssh-host.
      --ssh-identity-file <p>   Optional. SSH identity file for --ssh-host.
      --help                    Print this message.

    Default prompt:
      #{default_prompt}

    Runtime defaults:
      These examples default to ASM permission_mode=:bypass and print the provider-native
      permission term plus CLI flag before starting the run. Common prompt-based examples
      fail if the provider does not return the exact expected sentinel text.

    Provider environment:
      #{provider_env_lines}
    """
  end

  @spec fail!(String.t()) :: no_return()
  defp fail!(message) do
    IO.puts(message)
    System.halt(1)
  end
end
