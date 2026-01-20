defmodule AgentSessionManager.Core.RunTest do
  use ExUnit.Case, async: true
  alias AgentSessionManager.Core.Run

  describe "Run struct" do
    test "defines required fields" do
      run = %Run{}

      assert Map.has_key?(run, :id)
      assert Map.has_key?(run, :session_id)
      assert Map.has_key?(run, :status)
      assert Map.has_key?(run, :started_at)
      assert Map.has_key?(run, :ended_at)
    end

    test "defines optional fields" do
      run = %Run{}

      assert Map.has_key?(run, :input)
      assert Map.has_key?(run, :output)
      assert Map.has_key?(run, :error)
      assert Map.has_key?(run, :metadata)
      assert Map.has_key?(run, :turn_count)
      assert Map.has_key?(run, :token_usage)
    end

    test "has default values" do
      run = %Run{}

      assert run.status == :pending
      assert run.metadata == %{}
      assert run.turn_count == 0
      assert run.token_usage == %{}
      assert run.input == nil
      assert run.output == nil
      assert run.error == nil
    end
  end

  describe "Run.new/1" do
    test "creates a run with required session_id" do
      {:ok, run} = Run.new(%{session_id: "session-123"})

      assert run.session_id == "session-123"
      assert run.id != nil
      assert is_binary(run.id)
      assert run.status == :pending
      assert run.started_at != nil
    end

    test "generates a unique ID" do
      {:ok, run1} = Run.new(%{session_id: "session-123"})
      {:ok, run2} = Run.new(%{session_id: "session-123"})

      refute run1.id == run2.id
    end

    test "allows custom ID" do
      {:ok, run} = Run.new(%{id: "custom-run-id", session_id: "session-123"})

      assert run.id == "custom-run-id"
    end

    test "accepts input data" do
      {:ok, run} =
        Run.new(%{
          session_id: "session-123",
          input: %{prompt: "Hello, world!"}
        })

      assert run.input == %{prompt: "Hello, world!"}
    end

    test "accepts metadata" do
      {:ok, run} =
        Run.new(%{
          session_id: "session-123",
          metadata: %{model: "gpt-4", temperature: 0.7}
        })

      assert run.metadata == %{model: "gpt-4", temperature: 0.7}
    end

    test "returns error when session_id is missing" do
      result = Run.new(%{})

      assert {:error, error} = result
      assert error.code == :validation_error
      assert error.message =~ "session_id"
    end

    test "returns error when session_id is empty" do
      result = Run.new(%{session_id: ""})

      assert {:error, error} = result
      assert error.code == :validation_error
    end
  end

  describe "Run status transitions" do
    test "valid status values" do
      valid_statuses = [:pending, :running, :completed, :failed, :cancelled, :timeout]

      for status <- valid_statuses do
        {:ok, run} = Run.new(%{session_id: "session-123"})
        {:ok, updated} = Run.update_status(run, status)
        assert updated.status == status
      end
    end

    test "rejects invalid status values" do
      {:ok, run} = Run.new(%{session_id: "session-123"})
      result = Run.update_status(run, :invalid_status)

      assert {:error, error} = result
      assert error.code == :invalid_status
    end

    test "sets ended_at when transitioning to terminal status" do
      {:ok, run} = Run.new(%{session_id: "session-123"})

      {:ok, completed} = Run.update_status(run, :completed)
      assert completed.ended_at != nil

      {:ok, run2} = Run.new(%{session_id: "session-123"})
      {:ok, failed} = Run.update_status(run2, :failed)
      assert failed.ended_at != nil
    end

    test "does not set ended_at for non-terminal status" do
      {:ok, run} = Run.new(%{session_id: "session-123"})

      {:ok, running} = Run.update_status(run, :running)
      assert running.ended_at == nil
    end
  end

  describe "Run.set_output/2" do
    test "sets the output and marks as completed" do
      {:ok, run} = Run.new(%{session_id: "session-123"})
      {:ok, completed} = Run.set_output(run, %{response: "Hello!"})

      assert completed.output == %{response: "Hello!"}
      assert completed.status == :completed
      assert %DateTime{} = completed.ended_at
    end
  end

  describe "Run.set_error/2" do
    test "sets the error and marks as failed" do
      {:ok, run} = Run.new(%{session_id: "session-123"})
      error = %{code: :provider_error, message: "API timeout"}
      {:ok, failed} = Run.set_error(run, error)

      assert failed.error == error
      assert failed.status == :failed
      assert %DateTime{} = failed.ended_at
    end
  end

  describe "Run.increment_turn/1" do
    test "increments the turn count" do
      {:ok, run} = Run.new(%{session_id: "session-123"})
      assert run.turn_count == 0

      {:ok, run1} = Run.increment_turn(run)
      assert run1.turn_count == 1

      {:ok, run2} = Run.increment_turn(run1)
      assert run2.turn_count == 2
    end
  end

  describe "Run.update_token_usage/2" do
    test "updates token usage statistics" do
      {:ok, run} = Run.new(%{session_id: "session-123"})

      {:ok, updated} =
        Run.update_token_usage(run, %{
          input_tokens: 100,
          output_tokens: 50,
          total_tokens: 150
        })

      assert updated.token_usage == %{
               input_tokens: 100,
               output_tokens: 50,
               total_tokens: 150
             }
    end

    test "accumulates token usage across updates" do
      {:ok, run} = Run.new(%{session_id: "session-123"})

      {:ok, run1} = Run.update_token_usage(run, %{input_tokens: 100, output_tokens: 50})
      {:ok, run2} = Run.update_token_usage(run1, %{input_tokens: 200, output_tokens: 100})

      assert run2.token_usage == %{input_tokens: 300, output_tokens: 150}
    end
  end

  describe "Run.to_map/1" do
    test "converts run to a map for JSON serialization" do
      {:ok, run} =
        Run.new(%{
          session_id: "session-123",
          input: %{prompt: "test"},
          metadata: %{model: "gpt-4"}
        })

      map = Run.to_map(run)

      assert is_map(map)
      assert map["id"] == run.id
      assert map["session_id"] == "session-123"
      assert map["status"] == "pending"
      assert map["input"] == %{"prompt" => "test"}
      assert map["metadata"] == %{"model" => "gpt-4"}
      assert is_binary(map["started_at"])
    end
  end

  describe "Run.from_map/1" do
    test "reconstructs a run from a map" do
      {:ok, original} =
        Run.new(%{
          session_id: "session-123",
          input: %{prompt: "test"},
          metadata: %{model: "gpt-4"}
        })

      map = Run.to_map(original)
      {:ok, restored} = Run.from_map(map)

      assert restored.id == original.id
      assert restored.session_id == original.session_id
      assert restored.status == original.status
      assert restored.input == original.input
    end

    test "returns error for invalid map" do
      result = Run.from_map(%{})

      assert {:error, error} = result
      assert error.code == :validation_error
    end
  end
end
