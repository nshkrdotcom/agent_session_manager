defmodule ASM.ProviderBackend.SDK.CodexReviewedApprovalTest do
  use ExUnit.Case, async: true

  alias ASM.ProviderBackend.SDK.CodexReviewedApproval

  @content "NSHKR P04 governed Codex effect completed."
  @digest "sha256:" <> (:crypto.hash(:sha256, @content) |> Base.encode16(case: :lower))

  test "prepares one exact reviewed command and provider instruction" do
    assert {:ok, binding} = CodexReviewedApproval.prepare(attrs(), :auto_edit)

    assert binding.inner_command ==
             "printf '%s' 'TlNIS1IgUDA0IGdvdmVybmVkIENvZGV4IGVmZmVjdCBjb21wbGV0ZWQu' | base64 --decode > 'reviewed-codex-effect.txt'"

    assert binding.command == ~s(/bin/bash -lc "#{binding.inner_command}")

    assert CodexReviewedApproval.prompt("perform the reviewed effect", binding) =~
             "Execute exactly this one command"

    assert [
             approval_hook: CodexReviewedApproval,
             metadata: %{"asm_reviewed_codex_approval" => ^binding}
           ] = CodexReviewedApproval.thread_option_attrs(binding)
  end

  test "allows the exact command once and denies every broader approval family" do
    assert {:ok, binding} = CodexReviewedApproval.prepare(attrs(), :auto_edit)
    context = %{metadata: %{"asm_reviewed_codex_approval" => binding}}
    event = command_event(binding)

    assert :allow = CodexReviewedApproval.review_command(event, context, [])

    assert {:deny, "reviewed command approval was already consumed"} =
             CodexReviewedApproval.review_command(event, context, [])

    assert {:deny, _reason} =
             CodexReviewedApproval.review_command(
               %{event | command: "touch other.txt"},
               context,
               []
             )

    assert {:deny, _reason} = CodexReviewedApproval.review_file(%{}, context, [])
    assert {:deny, _reason} = CodexReviewedApproval.review_permissions(%{}, context, [])
    assert {:deny, _reason} = CodexReviewedApproval.review_tool(%{}, context, [])
  end

  test "rejects content drift, unsafe paths, and a non-auto provider posture" do
    assert {:error, :reviewed_content_digest_mismatch} =
             CodexReviewedApproval.prepare(%{attrs() | reviewed_content: "drift"}, :auto_edit)

    assert {:error, :invalid_reviewed_relative_path} =
             CodexReviewedApproval.prepare(%{attrs() | relative_path: "../other"}, :auto_edit)

    assert {:error, :reviewed_approval_requires_auto_edit} =
             CodexReviewedApproval.prepare(attrs(), :plan)
  end

  test "rejects command permission expansion" do
    assert {:ok, binding} = CodexReviewedApproval.prepare(attrs(), :auto_edit)
    context = %{metadata: %{"asm_reviewed_codex_approval" => binding}}

    event =
      binding
      |> command_event()
      |> Map.put(:network_approval_context, %{"host" => "example.com"})

    assert {:deny, "reviewed operation does not authorize network access"} =
             CodexReviewedApproval.review_command(event, context, [])

    expanded_action =
      binding
      |> command_event()
      |> put_in([:command_actions, Access.at(0), "path"], "/tmp/other")

    assert {:deny, "command actions do not match the reviewed operation"} =
             CodexReviewedApproval.review_command(expanded_action, context, [])
  end

  defp attrs do
    %{
      effect_ref: "effect://nshkr/codex/reviewed",
      workspace_root: "/tmp/nshkr-reviewed",
      relative_path: "reviewed-codex-effect.txt",
      reviewed_content: @content,
      content_digest: @digest
    }
  end

  defp command_event(binding) do
    %{
      command: binding.command,
      cwd: binding.workspace_root,
      command_actions: [%{"type" => "unknown", "command" => binding.inner_command}],
      proposed_execpolicy_amendment: binding.execpolicy_amendment,
      network_approval_context: nil,
      proposed_network_policy_amendments: [],
      additional_permissions: %{},
      skill_metadata: nil,
      thread_id: "thread-1",
      turn_id: "turn-1"
    }
  end
end
