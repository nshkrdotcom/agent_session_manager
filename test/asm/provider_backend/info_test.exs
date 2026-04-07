defmodule ASM.ProviderBackend.InfoTest do
  use ASM.TestCase

  alias ASM.ProviderBackend.Info

  test "session_event_tag/2 reads raw runtime info before normalization strips it" do
    raw_info = %{info: %{session_event_tag: :runtime_event_tag, token: "abc"}}

    assert Info.session_event_tag(raw_info) == :runtime_event_tag
  end

  test "new/1 strips raw session_event_tag from exposed session details" do
    info =
      Info.new(
        provider: :claude,
        lane: :sdk,
        backend: ASM.ProviderBackend.SDK,
        runtime: :runtime_probe,
        capabilities: [:streaming],
        raw_info: %{info: %{session_event_tag: :runtime_event_tag, token: "abc"}}
      )

    assert info.session.details == %{token: "abc"}
    refute Map.has_key?(info.session.details, :session_event_tag)
    refute Map.has_key?(info.session.details, "session_event_tag")
  end
end
