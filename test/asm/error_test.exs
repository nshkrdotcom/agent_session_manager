defmodule ASM.ErrorTest do
  use ASM.TestCase

  alias ASM.Error

  test "new/4 builds canonical error with optional fields" do
    error =
      Error.new(:timeout, :transport, "transport timed out",
        provider: :claude,
        exit_code: 124,
        retryable: true,
        recovery: %{"class" => "transport_timeout"}
      )

    assert error.kind == :timeout
    assert error.domain == :transport
    assert error.message == "transport timed out"
    assert error.provider == :claude
    assert error.exit_code == 124
    assert error.retryable == true
    assert error.recovery["class"] == "transport_timeout"
  end

  test "exception/1 uses defaults when fields are missing" do
    error = Error.exception([])

    assert error.kind == :unknown
    assert error.domain == :runtime
    assert error.message == "ASM runtime error"
  end

  test "Exception.message/1 includes domain and kind" do
    error = Error.new(:config_invalid, :config, "bad option")
    assert Exception.message(error) == "[config/config_invalid] bad option"
  end
end
