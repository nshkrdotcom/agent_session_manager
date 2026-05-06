defmodule ASM.PublicFacadeAuditTest do
  use ASM.SerialTestCase

  @facade [
    start_session: %{arity: 1, classification: :common_session_constructor},
    query: %{arity: 3, classification: :common},
    stream: %{arity: 3, classification: :common},
    stop_session: %{arity: 1, classification: :common_session_only},
    session_info: %{arity: 1, classification: :common_session_only},
    interrupt: %{arity: 2, classification: :partial_discovery},
    pause: %{arity: 2, classification: :partial_discovery},
    checkpoint: %{arity: 1, classification: :session_only_with_opaque_provider_payloads},
    resume_run: %{arity: 3, classification: :partial_discovery},
    intervene: %{arity: 4, classification: :partial_discovery},
    list_provider_sessions: %{arity: 2, classification: :provider_native_bridge},
    approve: %{arity: 3, classification: :partial_discovery}
  ]

  setup do
    original = Application.get_env(:agent_session_manager, ASM.ProviderRegistry)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:agent_session_manager, ASM.ProviderRegistry)
      else
        Application.put_env(:agent_session_manager, ASM.ProviderRegistry, original)
      end
    end)

    :ok
  end

  test "public facade audit covers every documented ASM facade function" do
    assert Keyword.keys(@facade) == [
             :start_session,
             :query,
             :stream,
             :stop_session,
             :session_info,
             :interrupt,
             :pause,
             :checkpoint,
             :resume_run,
             :intervene,
             :list_provider_sessions,
             :approve
           ]

    Enum.each(@facade, fn {function, %{arity: arity, classification: classification}} ->
      assert function_exported?(ASM, function, arity)

      assert classification in [
               :common,
               :common_session_constructor,
               :common_session_only,
               :session_only_with_opaque_provider_payloads,
               :partial_discovery,
               :provider_native_bridge
             ]
    end)
  end

  test "provider-native listing bridge fails clearly when SDK runtime is unavailable" do
    Application.put_env(:agent_session_manager, ASM.ProviderRegistry,
      runtime_loader: fn _runtime -> false end
    )

    assert {:error, error} = ASM.list_provider_sessions(:gemini)

    assert error.kind == :config_invalid
    assert error.domain == :provider
    assert String.contains?(error.message, "sdk runtime is unavailable")
  end

  test "partial session-control facades return stable errors for unknown runtime state" do
    session_id = "asm-public-facade-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert {:error, interrupt_error} = ASM.interrupt(session, "missing-run")
    assert interrupt_error.kind == :unknown
    assert interrupt_error.domain == :runtime

    assert {:error, pause_error} = ASM.pause(session, "missing-run")
    assert pause_error.kind == :unknown
    assert pause_error.domain == :runtime

    assert {:error, approval_error} = ASM.approve(session, "missing-approval", :allow)
    assert approval_error.kind == :unknown
    assert approval_error.domain == :approval

    assert :ok = ASM.stop_session(session)
  end
end
