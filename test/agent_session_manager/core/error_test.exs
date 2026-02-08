defmodule AgentSessionManager.Core.ErrorTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Error

  describe "Error struct" do
    test "defines required fields" do
      # Required fields (code and message are enforce_keys)
      error = Error.new(:validation_error, "Test error")

      assert Map.has_key?(error, :code)
      assert Map.has_key?(error, :message)
      assert error.code == :validation_error
      assert error.message == "Test error"
    end

    test "defines optional fields for context and details" do
      error = Error.new(:validation_error, "Test error")

      assert Map.has_key?(error, :details)
      assert Map.has_key?(error, :provider_error)
      assert Map.has_key?(error, :stacktrace)
      assert Map.has_key?(error, :timestamp)
      assert Map.has_key?(error, :context)
    end

    test "has default values" do
      error = Error.new(:validation_error, "Test error")

      assert error.details == %{}
      assert error.provider_error == nil
      assert error.stacktrace == nil
      assert error.context == %{}
    end
  end

  describe "Error codes - Validation errors" do
    test "validation_error is a valid code" do
      assert Error.valid_code?(:validation_error)
    end

    test "invalid_input is a valid code" do
      assert Error.valid_code?(:invalid_input)
    end

    test "missing_required_field is a valid code" do
      assert Error.valid_code?(:missing_required_field)
    end

    test "invalid_format is a valid code" do
      assert Error.valid_code?(:invalid_format)
    end
  end

  describe "Error codes - State/Status errors" do
    test "invalid_status is a valid code" do
      assert Error.valid_code?(:invalid_status)
    end

    test "invalid_transition is a valid code" do
      assert Error.valid_code?(:invalid_transition)
    end

    test "invalid_event_type is a valid code" do
      assert Error.valid_code?(:invalid_event_type)
    end

    test "invalid_capability_type is a valid code" do
      assert Error.valid_code?(:invalid_capability_type)
    end

    test "stream/event cursor errors are valid codes" do
      assert Error.valid_code?(:stream_closed)
      assert Error.valid_code?(:context_mismatch)
      assert Error.valid_code?(:invalid_cursor)
      assert Error.valid_code?(:session_mismatch)
      assert Error.valid_code?(:run_mismatch)
    end
  end

  describe "Error codes - Resource errors" do
    test "not_found is a valid code" do
      assert Error.valid_code?(:not_found)
    end

    test "session_not_found is a valid code" do
      assert Error.valid_code?(:session_not_found)
    end

    test "run_not_found is a valid code" do
      assert Error.valid_code?(:run_not_found)
    end

    test "capability_not_found is a valid code" do
      assert Error.valid_code?(:capability_not_found)
    end

    test "already_exists is a valid code" do
      assert Error.valid_code?(:already_exists)
    end

    test "duplicate_capability is a valid code" do
      assert Error.valid_code?(:duplicate_capability)
    end
  end

  describe "Error codes - Provider errors" do
    test "provider_error is a valid code" do
      assert Error.valid_code?(:provider_error)
    end

    test "provider_unavailable is a valid code" do
      assert Error.valid_code?(:provider_unavailable)
    end

    test "provider_rate_limited is a valid code" do
      assert Error.valid_code?(:provider_rate_limited)
    end

    test "provider_timeout is a valid code" do
      assert Error.valid_code?(:provider_timeout)
    end

    test "provider_authentication_failed is a valid code" do
      assert Error.valid_code?(:provider_authentication_failed)
    end

    test "provider_quota_exceeded is a valid code" do
      assert Error.valid_code?(:provider_quota_exceeded)
    end
  end

  describe "Error codes - Storage errors" do
    test "storage_error is a valid code" do
      assert Error.valid_code?(:storage_error)
    end

    test "storage_connection_failed is a valid code" do
      assert Error.valid_code?(:storage_connection_failed)
    end

    test "storage_write_failed is a valid code" do
      assert Error.valid_code?(:storage_write_failed)
    end

    test "storage_read_failed is a valid code" do
      assert Error.valid_code?(:storage_read_failed)
    end
  end

  describe "Error codes - Runtime errors" do
    test "timeout is a valid code" do
      assert Error.valid_code?(:timeout)
    end

    test "cancelled is a valid code" do
      assert Error.valid_code?(:cancelled)
    end

    test "policy_violation is a valid code" do
      assert Error.valid_code?(:policy_violation)
    end

    test "internal_error is a valid code" do
      assert Error.valid_code?(:internal_error)
    end

    test "unknown_error is a valid code" do
      assert Error.valid_code?(:unknown_error)
    end
  end

  describe "Error codes - Tool errors" do
    test "tool_error is a valid code" do
      assert Error.valid_code?(:tool_error)
    end

    test "tool_not_found is a valid code" do
      assert Error.valid_code?(:tool_not_found)
    end

    test "tool_execution_failed is a valid code" do
      assert Error.valid_code?(:tool_execution_failed)
    end

    test "tool_permission_denied is a valid code" do
      assert Error.valid_code?(:tool_permission_denied)
    end
  end

  describe "Error.valid_code?/1" do
    test "returns false for invalid codes" do
      refute Error.valid_code?(:invalid_code)
      refute Error.valid_code?(:made_up_error)
      refute Error.valid_code?("string_code")
      refute Error.valid_code?(123)
    end
  end

  describe "Error.all_codes/0" do
    test "returns list of all valid error codes" do
      codes = Error.all_codes()

      assert is_list(codes)
      refute Enum.empty?(codes)
      assert :validation_error in codes
      assert :provider_error in codes
      assert :storage_error in codes
      assert :timeout in codes
    end
  end

  describe "Error.new/2" do
    test "creates an error with code and message" do
      error = Error.new(:validation_error, "Invalid input provided")

      assert error.code == :validation_error
      assert error.message == "Invalid input provided"
      assert %DateTime{} = error.timestamp
    end

    test "creates error with default message for code" do
      error = Error.new(:validation_error)

      assert error.code == :validation_error
      assert is_binary(error.message)
      assert error.message != ""
    end
  end

  describe "Error.new/3 with options" do
    test "accepts details option" do
      error = Error.new(:validation_error, "Invalid input", details: %{field: "name", value: nil})

      assert error.details == %{field: "name", value: nil}
    end

    test "accepts provider_error option for wrapping provider errors" do
      provider_error = %{
        status_code: 429,
        body: "Rate limit exceeded",
        headers: %{"retry-after" => "60"}
      }

      error = Error.new(:provider_rate_limited, "Rate limited", provider_error: provider_error)

      assert error.provider_error == provider_error
    end

    test "accepts stacktrace option" do
      stacktrace = [{__MODULE__, :test, 1, [file: ~c"test.exs", line: 1]}]

      error = Error.new(:internal_error, "Something went wrong", stacktrace: stacktrace)

      assert error.stacktrace == stacktrace
    end

    test "accepts context option" do
      error =
        Error.new(:session_not_found, "Session not found",
          context: %{session_id: "session-123", operation: "get"}
        )

      assert error.context == %{session_id: "session-123", operation: "get"}
    end
  end

  describe "Error.wrap/2" do
    test "wraps an existing exception into an Error" do
      exception = RuntimeError.exception("Something broke")

      error = Error.wrap(:internal_error, exception)

      assert error.code == :internal_error
      assert error.message =~ "Something broke"
      assert error.details[:original_exception] == RuntimeError
    end

    test "wraps with custom message" do
      exception = ArgumentError.exception("bad arg")

      error = Error.wrap(:internal_error, exception, message: "Failed to process")

      assert error.message == "Failed to process"
      assert error.details[:original_message] == "bad arg"
    end
  end

  describe "Error.to_map/1" do
    test "converts error to a map for JSON serialization" do
      error =
        Error.new(:validation_error, "Invalid input",
          details: %{field: "name"},
          context: %{operation: "create"}
        )

      map = Error.to_map(error)

      assert is_map(map)
      assert map["code"] == "validation_error"
      assert map["message"] == "Invalid input"
      assert map["details"] == %{"field" => "name"}
      assert map["context"] == %{"operation" => "create"}
      assert is_binary(map["timestamp"])
    end

    test "handles nil optional fields" do
      error = Error.new(:validation_error, "Invalid input")

      map = Error.to_map(error)

      assert map["provider_error"] == nil
      assert map["stacktrace"] == nil
    end
  end

  describe "Error.from_map/1" do
    test "reconstructs an error from a map" do
      original = Error.new(:validation_error, "Invalid input", details: %{field: "name"})

      map = Error.to_map(original)
      {:ok, restored} = Error.from_map(map)

      assert restored.code == original.code
      assert restored.message == original.message
      assert restored.details == original.details
    end

    test "returns error for invalid map" do
      result = Error.from_map(%{})

      assert {:error, error} = result
      assert error.code == :validation_error
    end

    test "returns error for invalid code in map" do
      result =
        Error.from_map(%{
          "code" => "not_a_valid_code",
          "message" => "test"
        })

      assert {:error, error} = result
      assert error.code == :validation_error
    end
  end

  describe "Error categories" do
    test "validation_codes/0 returns validation error codes" do
      codes = Error.validation_codes()

      assert :validation_error in codes
      assert :invalid_input in codes
      assert :missing_required_field in codes
      refute :provider_error in codes
    end

    test "provider_codes/0 returns provider error codes" do
      codes = Error.provider_codes()

      assert :provider_error in codes
      assert :provider_unavailable in codes
      assert :provider_rate_limited in codes
      refute :validation_error in codes
    end

    test "storage_codes/0 returns storage error codes" do
      codes = Error.storage_codes()

      assert :storage_error in codes
      assert :storage_connection_failed in codes
      refute :validation_error in codes
    end

    test "resource_codes/0 returns resource error codes" do
      codes = Error.resource_codes()

      assert :not_found in codes
      assert :session_not_found in codes
      assert :already_exists in codes
      refute :validation_error in codes
    end

    test "runtime_codes/0 returns runtime error codes" do
      codes = Error.runtime_codes()

      assert :timeout in codes
      assert :cancelled in codes
      assert :internal_error in codes
      refute :validation_error in codes
    end

    test "tool_codes/0 returns tool error codes" do
      codes = Error.tool_codes()

      assert :tool_error in codes
      assert :tool_not_found in codes
      assert :tool_execution_failed in codes
      refute :validation_error in codes
    end
  end

  describe "Error.category/1" do
    test "returns category for validation errors" do
      assert Error.category(:validation_error) == :validation
      assert Error.category(:invalid_input) == :validation
    end

    test "returns category for provider errors" do
      assert Error.category(:provider_error) == :provider
      assert Error.category(:provider_rate_limited) == :provider
    end

    test "returns category for storage errors" do
      assert Error.category(:storage_error) == :storage
      assert Error.category(:storage_write_failed) == :storage
    end

    test "returns category for resource errors" do
      assert Error.category(:not_found) == :resource
      assert Error.category(:session_not_found) == :resource
    end

    test "returns category for runtime errors" do
      assert Error.category(:timeout) == :runtime
      assert Error.category(:internal_error) == :runtime
    end

    test "returns category for tool errors" do
      assert Error.category(:tool_error) == :tool
      assert Error.category(:tool_execution_failed) == :tool
    end

    test "returns :unknown for invalid codes" do
      assert Error.category(:not_a_real_code) == :unknown
    end
  end

  describe "Error.retryable?/1" do
    test "provider timeout is retryable" do
      assert Error.retryable?(:provider_timeout) == true
    end

    test "provider rate limited is retryable" do
      assert Error.retryable?(:provider_rate_limited) == true
    end

    test "provider unavailable is retryable" do
      assert Error.retryable?(:provider_unavailable) == true
    end

    test "storage connection failed is retryable" do
      assert Error.retryable?(:storage_connection_failed) == true
    end

    test "validation errors are not retryable" do
      assert Error.retryable?(:validation_error) == false
      assert Error.retryable?(:invalid_input) == false
    end

    test "not_found errors are not retryable" do
      assert Error.retryable?(:not_found) == false
      assert Error.retryable?(:session_not_found) == false
    end

    test "accepts Error struct" do
      error = Error.new(:provider_timeout, "Timeout")
      assert Error.retryable?(error) == true

      error2 = Error.new(:validation_error, "Invalid")
      assert Error.retryable?(error2) == false
    end
  end

  describe "Error implements String.Chars" do
    test "can be converted to string" do
      error = Error.new(:validation_error, "Invalid input provided")

      string = to_string(error)

      assert string =~ "validation_error"
      assert string =~ "Invalid input provided"
    end
  end

  describe "Error implements Exception behaviour" do
    test "can be raised using raise/2" do
      assert_raise Error, fn ->
        raise Error, code: :validation_error, message: "Invalid input"
      end
    end

    test "exception/1 creates an Error" do
      error = Error.exception(code: :validation_error, message: "Invalid input")

      assert %Error{} = error
      assert error.code == :validation_error
    end

    test "message/1 returns formatted error message" do
      error = Error.new(:validation_error, "Invalid input")
      assert Error.message(error) == "[validation_error] Invalid input"
    end
  end
end
