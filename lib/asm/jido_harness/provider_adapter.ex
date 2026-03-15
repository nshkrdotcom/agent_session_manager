defmodule ASM.JidoHarness.ProviderAdapter do
  @moduledoc false

  alias Jido.Harness.{Runtime, RuntimeContract}

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      @behaviour Jido.Harness.Adapter
      @behaviour Jido.Harness.RuntimeDriver
      @asm_harness_provider provider

      alias Jido.Harness.{Capabilities, RunRequest, SessionHandle}

      def id, do: @asm_harness_provider
      def runtime_id, do: ASM.JidoHarness.Driver.runtime_id()

      def runtime_descriptor(opts \\ []) do
        ASM.JidoHarness.Driver.runtime_descriptor(
          Keyword.put_new(opts, :provider, @asm_harness_provider)
        )
      end

      def start_session(opts) do
        ASM.JidoHarness.Driver.start_session(
          Keyword.put_new(opts, :provider, @asm_harness_provider)
        )
      end

      def stop_session(session), do: ASM.JidoHarness.Driver.stop_session(session)

      def stream_run(%SessionHandle{} = session, %RunRequest{} = request, opts) do
        ASM.JidoHarness.Driver.stream_run(
          session,
          request,
          Keyword.put_new(opts, :provider, @asm_harness_provider)
        )
      end

      def run(%SessionHandle{} = session, %RunRequest{} = request, opts) do
        ASM.JidoHarness.Driver.run(
          session,
          request,
          Keyword.put_new(opts, :provider, @asm_harness_provider)
        )
      end

      def run(%RunRequest{} = request, opts) do
        Runtime.stream_legacy_events(__MODULE__, request, opts)
      end

      def cancel(session_id) when is_binary(session_id), do: ASM.stop_session(session_id)
      def cancel_run(session, run), do: ASM.JidoHarness.Driver.cancel_run(session, run)
      def session_status(session), do: ASM.JidoHarness.Driver.session_status(session)

      def approve(session, approval_id, decision, opts),
        do: ASM.JidoHarness.Driver.approve(session, approval_id, decision, opts)

      def cost(session), do: ASM.JidoHarness.Driver.cost(session)

      def capabilities do
        descriptor = runtime_descriptor()
        provider_info = ASM.Provider.resolve!(@asm_harness_provider)

        %Capabilities{
          streaming?: descriptor.streaming?,
          tool_calls?: provider_info.supports_tools,
          tool_results?: provider_info.supports_tools,
          thinking?: provider_info.supports_thinking,
          resume?: descriptor.resume?,
          usage?: descriptor.cost?,
          file_changes?: false,
          cancellation?: descriptor.cancellation?
        }
      end

      def runtime_contract do
        ASM.JidoHarness.ProviderAdapter.runtime_contract(@asm_harness_provider)
      end
    end
  end

  @spec runtime_contract(atom()) :: RuntimeContract.t()
  def runtime_contract(provider_name) when is_atom(provider_name) do
    provider = ASM.Provider.resolve!(provider_name)

    RuntimeContract.new!(%{
      provider: provider_name,
      host_env_required_any: env_var_list(provider.env_var),
      host_env_required_all: [],
      sprite_env_forward: env_var_list(provider.env_var),
      sprite_env_injected: %{},
      runtime_tools_required: provider.binary_names,
      compatibility_probes: compatibility_probes(provider),
      install_steps: install_steps(provider),
      auth_bootstrap_steps: auth_bootstrap_steps(provider),
      triage_command_template: "ASM runtime-managed #{provider_name} triage",
      coding_command_template: "ASM runtime-managed #{provider_name} coding",
      success_markers: [%{"type" => "result"}, %{"type" => "run_completed"}]
    })
  end

  defp env_var_list(nil), do: []
  defp env_var_list(env_var), do: [env_var]

  defp compatibility_probes(provider) do
    case provider.binary_names do
      [binary | _rest] ->
        [%{"name" => "#{provider.name}_help", "command" => "#{binary} --help"}]

      [] ->
        []
    end
  end

  defp install_steps(%{install_command: nil}), do: []

  defp install_steps(provider) do
    tool =
      case provider.binary_names do
        [binary | _rest] -> binary
        [] -> Atom.to_string(provider.name)
      end

    [%{"tool" => tool, "when_missing" => true, "command" => provider.install_command}]
  end

  defp auth_bootstrap_steps(%{env_var: nil}), do: []

  defp auth_bootstrap_steps(provider) do
    [
      "Set #{provider.env_var} if you need an explicit CLI path for #{provider.display_name}",
      "Authenticate #{provider.display_name} with its native CLI flow before starting ASM sessions"
    ]
  end
end
