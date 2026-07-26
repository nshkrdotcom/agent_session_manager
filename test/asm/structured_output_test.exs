defmodule ASM.StructuredOutputTest do
  use ASM.TestCase

  alias ASM.{Error, Event, Options, ProviderFeatures, Result, Run}
  alias CliSubprocessCore.Payload

  @schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "string"}},
    "required" => ["answer"]
  }

  describe "structured_output capability manifest" do
    test "claude declares inline JSON as its wire form" do
      manifest = ProviderFeatures.common_feature!(:claude, :structured_output)

      assert manifest.supported? == true
      assert manifest.common_surface == true
      assert manifest.common_opts == [:output_schema]
      assert manifest.compatibility.wire_form == :inline_json
      assert manifest.compatibility.cli_flag == "--json-schema"
      assert ProviderFeatures.supports_common_feature?(:claude, :structured_output)
    end

    test "codex declares a schema file path as its wire form" do
      manifest = ProviderFeatures.common_feature!(:codex, :structured_output)

      assert manifest.supported? == true
      assert manifest.compatibility.wire_form == :file_path
      assert manifest.compatibility.cli_flag == "--output-schema"
      assert ProviderFeatures.supports_common_feature?(:codex, :structured_output)
    end

    test "cursor, amp, and antigravity report structured output as unsupported" do
      for provider <- [:cursor, :amp, :antigravity] do
        manifest = ProviderFeatures.common_feature!(provider, :structured_output)

        assert manifest.supported? == false
        assert manifest.compatibility == nil
        assert manifest.notes != []
        refute ProviderFeatures.supports_common_feature?(provider, :structured_output)
      end
    end
  end

  describe "run-path capability gate" do
    test "codex accepts output_schema" do
      assert {:ok, validated} =
               Options.validate(
                 [provider: :codex, output_schema: @schema],
                 Options.Codex.schema()
               )

      assert Keyword.fetch!(validated, :output_schema) == @schema
    end

    test "claude accepts output_schema" do
      assert {:ok, validated} =
               Options.validate(
                 [provider: :claude, output_schema: @schema],
                 Options.Claude.schema()
               )

      assert Keyword.fetch!(validated, :output_schema) == @schema
    end

    test "cursor is refused with a typed capability error, not a schema shape error" do
      assert {:error, %Error{} = error} =
               Options.validate(
                 [provider: :cursor, output_schema: @schema],
                 Options.Cursor.schema()
               )

      assert error.kind == :config_invalid
      assert error.domain == :config
      assert error.message =~ ":cursor"
      assert error.message =~ ":output_schema"
      assert error.message =~ ":structured_output"
      refute error.message =~ "unknown options"
      refute match?(%NimbleOptions.ValidationError{}, error.cause)
    end

    test "amp is refused with a typed capability error" do
      assert {:error, %Error{} = error} =
               Options.validate(
                 [provider: :amp, output_schema: @schema],
                 Options.Amp.schema()
               )

      assert error.kind == :config_invalid
      assert error.message =~ ":amp"
      assert error.message =~ ":structured_output"
    end

    test "a nil output_schema never trips the gate" do
      assert {:ok, validated} =
               Options.validate(
                 [provider: :cursor, output_schema: nil],
                 Options.Cursor.schema()
               )

      assert Keyword.get(validated, :output_schema) == nil
    end
  end

  describe "provider-returned object on the return path" do
    test "the result event carries the provider object into ASM.Result" do
      object = %{"answer" => "42"}

      event =
        Event.new(
          :result,
          Payload.Result.new(
            status: :completed,
            stop_reason: :end_turn,
            object: object,
            output: %{duration_ms: 12}
          ),
          run_id: "run-object",
          session_id: "session-object",
          provider: :codex,
          timestamp: DateTime.utc_now()
        )

      legacy = Event.legacy_payload(event)
      assert %ASM.Message.Result{} = legacy
      assert legacy.object == object

      state =
        Run.State.new(run_id: "run-object", session_id: "session-object", provider: :codex)

      state = Run.EventReducer.apply_event!(state, event)

      assert %Result{object: ^object} = state.result
      assert %Result{object: ^object} = Run.EventReducer.to_result(state)
    end

    test "a result without an object projects nil" do
      event =
        Event.new(
          :result,
          Payload.Result.new(status: :completed, stop_reason: :end_turn),
          run_id: "run-plain",
          session_id: "session-plain",
          provider: :claude,
          timestamp: DateTime.utc_now()
        )

      state =
        Run.State.new(run_id: "run-plain", session_id: "session-plain", provider: :claude)

      state = Run.EventReducer.apply_event!(state, event)

      assert %Result{object: nil} = Run.EventReducer.to_result(state)
    end
  end
end
