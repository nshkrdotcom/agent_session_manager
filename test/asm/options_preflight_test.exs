defmodule ASM.OptionsPreflightTest do
  use ASM.TestCase

  alias ASM.Options

  alias ASM.Options.{
    PartialFeatureUnsupportedError,
    ProviderMismatchError,
    ProviderNativeOptionError,
    UnsupportedExecutionSurfaceError,
    UnsupportedOptionError,
    Warning
  }

  alias CliSubprocessCore.ExecutionSurface

  test "strict common preflight classifies only common and session/runtime options" do
    assert {:ok, result} =
             Options.preflight(:gemini,
               model: "fake-default",
               lane: :core,
               cwd: "/tmp/asm",
               execution_surface: [surface_kind: ExecutionSurface.default_surface_kind()]
             )

    assert result.provider == :gemini
    assert result.mode == :strict_common
    assert result.common.model == "fake-default"
    assert result.common.cwd == "/tmp/asm"
    assert %ExecutionSurface{} = result.common.execution_surface
    assert result.session.lane == :core
    assert result.partial == %{}
    assert result.provider_native_legacy == %{}
    assert result.warnings == []
  end

  test "strict common preflight rejects redundant provider in provider-positional APIs" do
    assert {:error, %ProviderMismatchError{} = error} =
             Options.preflight(:gemini, provider: :gemini, model: "fake-default")

    assert error.reason == :redundant_provider
    assert error.expected_provider == :gemini
    assert error.actual_provider == :gemini
  end

  test "provider mismatch is rejected before session startup compatibility handling" do
    assert {:error, %ProviderMismatchError{} = redundant_error} =
             Options.ensure_positional_provider(:gemini, provider: :gemini)

    assert redundant_error.reason == :redundant_provider
    assert redundant_error.mode == :strict_common

    assert {:error, %ProviderMismatchError{} = error} =
             Options.ensure_positional_provider(:gemini, provider: :claude)

    assert error.reason == :mismatch
    assert error.expected_provider == :gemini
    assert error.actual_provider == :claude
  end

  test "compat preflight classifies matching provider as legacy metadata with a warning" do
    assert {:ok, result} =
             Options.preflight(:gemini, [provider: :gemini, model: "fake-default"], mode: :compat)

    assert result.common.model == "fake-default"
    assert result.provider_native_legacy.provider == :gemini
    assert [%Warning{key: :provider, reason: :redundant_provider}] = result.warnings
  end

  test "strict common preflight rejects provider-native options" do
    assert {:error, %ProviderNativeOptionError{} = error} =
             Options.preflight(:gemini, system_prompt: "act like a plain LLM")

    assert error.key == :system_prompt
    assert error.provider == :gemini
    assert error.reason == :provider_native
    assert error.migration =~ "provider SDK"
  end

  test "strict common preflight keeps sandboxing on execution_surface, not provider flags" do
    assert {:ok, result} =
             Options.preflight(:gemini,
               execution_surface: [
                 surface_kind: :local_subprocess,
                 boundary_class: :local_weak
               ]
             )

    assert result.common.execution_surface.boundary_class == :local_weak

    assert {:error, %ProviderNativeOptionError{} = error} =
             Options.preflight(:gemini, sandbox: true)

    assert error.key == :sandbox
    assert error.reason == :provider_native
    assert error.migration =~ "provider SDK"
  end

  test "strict common preflight rejects legacy permission and internal model payload keys" do
    assert {:error, %ProviderNativeOptionError{} = permission_error} =
             Options.preflight(:codex, permission_mode: :bypass)

    assert permission_error.key == :permission_mode

    assert {:error, %ProviderNativeOptionError{} = payload_error} =
             Options.preflight(:codex, model_payload: %{id: "fake-default"})

    assert payload_error.key == :model_payload
  end

  test "strict common preflight rejects unadmitted tool contracts" do
    assert {:error, %ProviderNativeOptionError{} = error} =
             Options.preflight(:amp, tools: [%{name: "search"}])

    assert error.key == :tools
    assert error.reason == :provider_native
    assert error.migration =~ "provider SDK"
  end

  test "strict common preflight rejects every host-tool admission key for every provider" do
    for provider <- [:claude, :codex, :gemini, :amp],
        {key, value} <- [
          tools: [%{name: "search"}],
          host_tools: [%{name: "lookup"}],
          dynamic_tools: [%{"name" => "lookup"}]
        ] do
      assert {:error, %ProviderNativeOptionError{} = error} =
               Options.preflight(provider, [{key, value}])

      assert error.key == key
      assert error.provider == provider
      assert error.reason == :provider_native
      assert error.migration =~ "provider SDK"
    end
  end

  test "compat preflight classifies provider-native options with structured warnings" do
    assert {:ok, result} =
             Options.preflight(:codex, [provider_backend: :oss, model_provider: "gateway"],
               mode: :compat
             )

    assert result.provider_native_legacy.provider_backend == :oss
    assert result.provider_native_legacy.model_provider == "gateway"
    assert Enum.all?(result.warnings, &match?(%Warning{reason: :provider_native}, &1))
  end

  test "compat preflight still rejects newly invented provider-specific option names" do
    assert {:error, %UnsupportedOptionError{} = error} =
             Options.preflight(:gemini, [answer_only: true], mode: :compat)

    assert error.key == :answer_only
    assert error.reason == :unknown_option
  end

  test "strict common preflight rejects partial features until all-provider proof exists" do
    assert {:error, %PartialFeatureUnsupportedError{} = error} =
             Options.preflight(:claude, ollama: true)

    assert error.key == :ollama
    assert error.feature == :ollama
  end

  test "strict common preflight rejects env and args escape hatches" do
    assert {:error, %ProviderNativeOptionError{} = env_error} =
             Options.preflight(:gemini, env: %{"GEMINI_API_KEY" => "redacted"})

    assert env_error.key == :env
    assert env_error.reason == :escape_hatch

    assert {:error, %ProviderNativeOptionError{} = args_error} =
             Options.preflight(:gemini, args: ["--tools", "none"])

    assert args_error.key == :args
    assert args_error.reason == :escape_hatch
  end

  test "compat preflight flags high-risk provider environment aliases" do
    assert {:ok, result} =
             Options.preflight(:gemini, [env: %{"GEMINI_API_KEY" => "redacted"}], mode: :compat)

    assert result.provider_native_legacy.env == %{"GEMINI_API_KEY" => "redacted"}
    assert [%Warning{key: :env, reason: :provider_native_env, message: message}] = result.warnings
    assert message =~ "GEMINI_API_KEY"
  end

  test "strict common preflight rejects invalid lanes and unknown options" do
    assert {:error, %UnsupportedOptionError{} = lane_error} =
             Options.preflight(:gemini, lane: :provider_native)

    assert lane_error.key == :lane
    assert lane_error.reason == :invalid_lane

    assert {:error, %UnsupportedOptionError{} = unknown_error} =
             Options.preflight(:gemini, prompt_prefix: "nope")

    assert unknown_error.key == :prompt_prefix
    assert unknown_error.reason == :unknown_option
  end

  test "strict common preflight reports invalid execution surfaces with a stable category" do
    assert {:error, %UnsupportedExecutionSurfaceError{} = error} =
             Options.preflight(:gemini, execution_surface: [surface_kind: :definitely_not_real])

    assert error.reason != nil
  end

  test "preflight does not load optional provider SDK runtime modules" do
    sdk_runtime = Module.concat(["GeminiCliSdk", "Runtime", "CLI"])

    if :code.is_loaded(sdk_runtime) == false do
      assert {:ok, _result} = Options.preflight(:gemini, model: "fake-default", lane: :core)
      assert :code.is_loaded(sdk_runtime) == false
    end
  end
end
