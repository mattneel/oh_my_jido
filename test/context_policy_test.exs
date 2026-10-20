defmodule OhMyJido.ContextPolicyTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Model.Response
  alias Jido.AI.Thread.Projection
  alias OhMyJido.ContextPolicy
  alias ReqLLM.Message.ContentPart

  test "completed native question evidence survives provenance, projection and checkpoint restore" do
    assert {:ok, policy} = ContextPolicy.new(max_messages: 3, keep_recent: 3)
    id = "Ask before deciding-0"
    arguments = %{"question" => "Which public API must remain?"}
    wire_call = ReqLLM.ToolCall.new(id, "question", Jason.encode!(arguments))
    answer = Response.format_tool_result_content({:ok, %{answer: "Keep the API"}, []})

    assert {:ok, pending} =
             Projection.append(Jido.Session.new(), [
               ReqLLM.Context.user("Ask before deciding"),
               ReqLLM.Context.assistant("", tool_calls: [wire_call])
             ])

    assert {:ok, running} =
             Projection.append(pending, [ReqLLM.Context.tool_result(id, "question", answer)])

    assert {:ok, running_messages} = Projection.evidence_messages(running)
    assert {:ok, observed} = ContextPolicy.compact(policy, running_messages)

    checkpoint =
      observed.state |> ContextPolicy.checkpoint() |> Jason.encode!() |> Jason.decode!()

    assert {:ok, restored} = ContextPolicy.restore(checkpoint)

    assert {:ok, completed} =
             Projection.append(
               pending,
               [ReqLLM.Context.tool_result(id, "question", answer)],
               %{request_id: "request-1", run_id: "request-1", signal_id: "result-event-1"}
             )

    assert {:ok, completed} =
             Projection.append(completed, [
               ReqLLM.Context.assistant("The operator constraint is retained."),
               ReqLLM.Context.user("Continue without changing the API")
             ])

    assert {:ok, completed_messages} = Projection.messages(completed)
    assert {:ok, next} = ContextPolicy.compact(restored, completed_messages)
    assert next.compacted
    assert next.state.completed_tools == observed.state.completed_tools
    assert next.state.pending_tools == %{}
    assert Enum.any?(next.messages, &(message_text(&1) =~ "Keep the API"))
    assert Enum.any?(next.messages, &(Map.get(&1, :tool_calls) == [wire_call]))

    assert {:ok, canonical} = ReqLLM.Context.normalize(next.messages)
    assert {:ok, normalized} = ContextPolicy.compact(next.state, canonical.messages)
    assert normalized.state.completed_tools == observed.state.completed_tools
    assert normalized.state.summary == next.state.summary

    assert Enum.count(
             normalized.messages,
             &(message_text(&1) =~ "Retained task context (quoted data")
           ) == 1

    checkpoint =
      normalized.state |> ContextPolicy.checkpoint() |> Jason.encode!() |> Jason.decode!()

    assert {:ok, restored} = ContextPolicy.restore(checkpoint)

    assert {:ok, projected_session} = Projection.append(Jido.Session.new(), normalized.messages)
    assert {:ok, projected} = Projection.messages(projected_session)

    assert {:ok, repeated} = ContextPolicy.compact(restored, projected)
    assert repeated.state.completed_tools == observed.state.completed_tools
    assert repeated.state.summary == normalized.state.summary
    assert Enum.any?(repeated.messages, &(message_text(&1) =~ "Keep the API"))

    for {name, changed} <- [
          {"question", %{"question" => "May I replace the API?"}},
          {"read", arguments}
        ] do
      changed_call = ReqLLM.ToolCall.new(id, name, Jason.encode!(changed))

      changed_arguments =
        Enum.map(canonical.messages, fn
          %ReqLLM.Message{role: :assistant, tool_calls: [_call]} = message ->
            %{message | tool_calls: [changed_call]}

          message ->
            message
        end)

      assert {:error, {:tool_call_reused, ^id}} =
               ContextPolicy.compact(restored, changed_arguments)
    end

    changed_result =
      Enum.map(canonical.messages, fn
        %ReqLLM.Message{role: :tool, tool_call_id: ^id} ->
          changed = Response.format_tool_result_content({:ok, %{answer: "Replace the API"}, []})

          ReqLLM.Context.tool_result(id, "question", changed)

        message ->
          message
      end)

    assert {:error, {:tool_evidence_conflict, ^id}} =
             ContextPolicy.compact(restored, changed_result)
  end

  test "native model entry timestamps remain portable provenance during compaction" do
    assert {:ok, policy} = ContextPolicy.new()
    [message] = Jido.AI.Model.Messages.entries([ReqLLM.Context.user("Keep the native entry")])
    assert %DateTime{} = message.timestamp
    assert {:ok, projection} = ContextPolicy.compact(policy, [message])
    assert message in projection.messages
    assert {:ok, _restored} = ContextPolicy.restore(ContextPolicy.checkpoint(projection.state))

    assert {:error, :invalid_context_messages} =
             ContextPolicy.compact(policy, [%{message | timestamp: self()}])
  end

  test "native multimodal tool evidence keeps image bytes immutable and enforces the full byte budget" do
    assert {:ok, policy} = ContextPolicy.new(max_messages: 3, keep_recent: 3)
    id = "artifact-image-1"
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 255>>
    image = ContentPart.image(bytes, "image/png")

    content =
      Response.format_tool_result_content(
        {:ok, %{path: "diagram.png", __content_parts__: [image]}, []}
      )

    tool_call = ReqLLM.ToolCall.new(id, "artifact", Jason.encode!(%{"path" => "diagram.png"}))

    assert {:ok, pending} =
             Projection.append(Jido.Session.new(), [
               ReqLLM.Context.user("Inspect the diagram"),
               ReqLLM.Context.assistant("", tool_calls: [tool_call])
             ])

    assert {:ok, observed_context} =
             Projection.append(pending, [ReqLLM.Context.tool_result(id, "artifact", content)])

    assert {:ok, observed_messages} = Projection.evidence_messages(observed_context)
    assert {:ok, observed} = ContextPolicy.compact(policy, observed_messages)

    checkpoint =
      observed.state |> ContextPolicy.checkpoint() |> Jason.encode!() |> Jason.decode!()

    assert {:ok, restored} = ContextPolicy.restore(checkpoint)

    assert {:ok, completed} =
             Projection.append(
               pending,
               [ReqLLM.Context.tool_result(id, "artifact", content)],
               %{request_id: "image-request", run_id: "image-request", signal_id: "image-event"}
             )

    assert {:ok, completed} =
             Projection.append(completed, [
               ReqLLM.Context.assistant("The diagram is visible."),
               ReqLLM.Context.user("Explain the diagram")
             ])

    assert {:ok, completed_messages} = Projection.messages(completed)
    assert {:ok, projected} = ContextPolicy.compact(restored, completed_messages)

    assert projected.state.completed_tools == observed.state.completed_tools
    result = Enum.find(projected.messages, &(Map.get(&1, :tool_call_id) == id))
    assert result.content == content
    assert image in result.content
    assert {:ok, canonical} = ReqLLM.Context.normalize(projected.messages)
    assert {:ok, normalized} = ContextPolicy.compact(projected.state, canonical.messages)
    assert normalized.state.completed_tools == observed.state.completed_tools

    assert {:ok, changed_context} =
             Projection.append(pending, [
               ReqLLM.Context.tool_result(id, "artifact", [
                 hd(content),
                 ContentPart.image(bytes <> <<0>>, "image/png")
               ])
             ])

    assert {:ok, changed} = Projection.evidence_messages(changed_context)

    assert {:error, {:tool_evidence_conflict, ^id}} = ContextPolicy.compact(restored, changed)

    oversized_image =
      ContentPart.image(:binary.copy(<<137, 255>>, policy.options.max_bytes), "image/png")

    oversized = [
      call("oversized-image", "artifact", %{path: "large.png"}),
      result("oversized-image", "artifact", [ContentPart.text("Observed image"), oversized_image])
    ]

    assert {:error, :context_budget_exceeded} = ContextPolicy.compact(policy, oversized)
  end

  test "immutable argument evidence is hashed before durable credential-field redaction" do
    assert {:ok, policy} = ContextPolicy.new([])
    id = "protected-read"
    argument_secret = "synthetic-context-argument-secret-A"
    result_secret = "synthetic-context-result-secret-B"
    secrets = [argument_secret, result_secret]
    arguments = %{"path" => "private-reference.txt", "api_key" => argument_secret}
    tool_call = ReqLLM.ToolCall.new(id, "read", Jason.encode!(arguments))

    messages = [
      ReqLLM.Context.user("Read the protected reference"),
      ReqLLM.Context.assistant("", tool_calls: [tool_call]),
      ReqLLM.Context.tool_result(id, "read", "Observed " <> result_secret)
    ]

    assert {:ok, observed} = ContextPolicy.compact(policy, messages, secrets: secrets)
    checkpoint = ContextPolicy.checkpoint(observed.state)
    encoded = Jason.encode!(checkpoint)
    refute encoded =~ argument_secret
    refute encoded =~ result_secret
    assert {:ok, restored} = ContextPolicy.restore(Jason.decode!(encoded))
    assert {:ok, repeated} = ContextPolicy.compact(restored, messages, secrets: secrets)
    assert repeated.state.completed_tools == observed.state.completed_tools

    changed_arguments = Map.put(arguments, "api_key", "synthetic-context-argument-secret-C")
    changed_call = ReqLLM.ToolCall.new(id, "read", Jason.encode!(changed_arguments))

    changed =
      List.replace_at(messages, 1, ReqLLM.Context.assistant("", tool_calls: [changed_call]))

    assert {:error, {:tool_call_reused, ^id}} =
             ContextPolicy.compact(restored, changed, secrets: secrets)

    assert {:error, :unsupported_context_policy_version} =
             ContextPolicy.restore(Map.put(checkpoint, "version", 1))
  end

  test "compaction and JSON checkpoint restart retain task-critical facts without replayable effects" do
    assert {:ok, state} = ContextPolicy.new(max_messages: 4, keep_recent: 2)

    assert {:ok, state} =
             ContextPolicy.retain(state, %{
               goal: "Repair the parser without changing its API",
               constraints: ["No external network", "Preserve return values"],
               file_facts: %{
                 "lib/parser.ex" => %{
                   digest: "observed-hash",
                   fact: "empty input currently crashes"
                 }
               },
               memory: %{"decision" => "Keep parser state immutable"},
               unresolved_work: ["Run parser regression tests"]
             })

    messages = [
      %{role: :system, content: "Trusted coding instructions"},
      %{role: :user, content: "Repair the parser without changing its API"},
      call("edit-1", "edit", %{path: "lib/parser.ex"}),
      result("edit-1", "edit", "Applied the targeted snapshot edit"),
      %{role: :assistant, content: "The edit is complete; verification is still pending"},
      %{role: :user, content: "Continue with verification"}
    ]

    assert {:ok,
            %{compacted: true, state: compacted, messages: projected, removed_messages: removed}} =
             ContextPolicy.compact(state, messages)

    assert removed > 0
    assert {:ok, _valid} = ReqLLM.Context.normalize(projected)
    text = Enum.map_join(projected, "\n", &message_text/1)

    for fact <- [
          "Repair the parser",
          "No external network",
          "Preserve return values",
          "lib/parser.ex",
          "observed-hash",
          "Keep parser state immutable",
          "Run parser regression tests",
          "edit-1"
        ] do
      assert text =~ fact
    end

    assert compacted.completed_tools["edit-1"].name == "edit"
    refute Enum.any?(projected, &(Map.get(&1, :tool_call_id) == "edit-1"))

    checkpoint = compacted |> ContextPolicy.checkpoint() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, restored} = ContextPolicy.restore(checkpoint)
    assert restored.retained == compacted.retained
    assert restored.completed_tools == compacted.completed_tools

    assert {:ok, repeated} = ContextPolicy.compact(restored, messages)
    assert repeated.messages == projected
    assert repeated.state.summary == compacted.summary
    assert repeated.state.completed_tools == compacted.completed_tools
  end

  test "recent projection expands boundaries to retain an entire parallel tool exchange" do
    assert {:ok, state} = ContextPolicy.new(max_messages: 4, keep_recent: 2)

    calls = %{
      role: :assistant,
      content: "Read both files",
      tool_calls: [
        %{id: "read-a", name: "read", arguments: %{path: "a.ex"}},
        %{id: "read-b", name: "read", arguments: %{path: "b.ex"}}
      ]
    }

    messages = [
      %{role: :user, content: "Compare files"},
      %{role: :assistant, content: "I will inspect them"},
      calls,
      result("read-b", "read", "b contents"),
      result("read-a", "read", "a contents"),
      %{role: :user, content: "What differs?"}
    ]

    assert {:ok, %{messages: projected}} = ContextPolicy.compact(state, messages)
    assert calls in projected
    assert result("read-a", "read", "a contents") in projected
    assert result("read-b", "read", "b contents") in projected
    assert {:ok, _valid} = ReqLLM.Context.normalize(projected)
  end

  test "pending and delayed tool results never lose their originating calls" do
    assert {:ok, state} = ContextPolicy.new(max_messages: 3, keep_recent: 1)
    pending = call("pending", "exec", %{command: "long-running"})
    messages = [pending | Enum.map(1..8, &%{role: :user, content: "steering #{&1}"})]

    assert {:ok, %{messages: projected, state: retained}} = ContextPolicy.compact(state, messages)
    assert pending in projected
    assert Map.has_key?(retained.pending_tools, "pending")
    refute Map.has_key?(retained.completed_tools, "pending")

    completed = messages ++ [result("pending", "exec", "finished")]

    assert {:ok, %{messages: with_result, state: resolved}} =
             ContextPolicy.compact(retained, completed)

    assert pending in with_result
    assert result("pending", "exec", "finished") in with_result
    refute Map.has_key?(resolved.pending_tools, "pending")
  end

  test "orphaned, duplicate and mismatched results are rejected rather than silently suppressed" do
    assert {:ok, state} = ContextPolicy.new([])

    assert {:error, {:orphan_tool_result, "missing"}} =
             ContextPolicy.compact(state, [result("missing", "edit", "ok")])

    duplicate = [
      call("one", "read", %{}),
      result("one", "read", "ok"),
      result("one", "read", "again")
    ]

    assert {:error, {:duplicate_tool_result, "one"}} = ContextPolicy.compact(state, duplicate)

    mismatch = [call("one", "read", %{}), result("one", "exec", "ok")]
    assert {:error, {:tool_name_mismatch, "one"}} = ContextPolicy.compact(state, mismatch)

    reused = [call("one", "read", %{}), result("one", "read", "ok"), call("one", "exec", %{})]
    assert {:error, {:duplicate_tool_call, "one"}} = ContextPolicy.compact(state, reused)
  end

  test "canonical ReqLLM messages preserve reasoning and tool metadata unchanged" do
    assert {:ok, state} = ContextPolicy.new(max_messages: 3, keep_recent: 2)
    tool_call = ReqLLM.ToolCall.new("canonical", "read", "{}")

    assistant =
      ReqLLM.Context.assistant("Reading", tool_calls: [tool_call], metadata: %{source: "fixture"})

    assistant = %{assistant | reasoning_details: [%{signature: "opaque-reasoning-signature"}]}
    result = ReqLLM.Context.tool_result("canonical", "read", "contents")

    messages = [
      ReqLLM.Context.user("original goal"),
      assistant,
      result,
      ReqLLM.Context.user("next task")
    ]

    assert {:ok, %{messages: projected}} = ContextPolicy.compact(state, messages)
    assert assistant in projected
    assert result in projected
  end

  test "retention updates are data-only and oversize mandatory facts fail instead of disappearing" do
    assert {:ok, state} = ContextPolicy.new(max_retained_bytes: 512)

    assert {:error, :nonserializable_context} =
             ContextPolicy.retain(state, %{memory: %{"unsafe" => fn -> :execute end}})

    assert {:error, :nonserializable_context} =
             ContextPolicy.retain(state, %{memory: %{"process" => self()}})

    assert {:error, :retained_context_too_large} =
             ContextPolicy.retain(state, %{goal: String.duplicate("required fact ", 100)})

    assert {:error, :unsupported_context_policy_version} =
             ContextPolicy.restore(%{"version" => 99})

    assert {:ok, first} =
             ContextPolicy.retain(state, %{
               constraints: ["Keep the API"],
               unresolved_work: ["Fix", "Test"]
             })

    assert {:ok, next} =
             ContextPolicy.retain(first, %{
               constraints: ["Keep the API", "No network"],
               unresolved_work: ["Test"]
             })

    assert next.retained.constraints == ["Keep the API", "No network"]
    assert next.retained.unresolved_work == ["Test"]
  end

  test "summary continuity survives native Jido projection without relying on message metadata" do
    assert {:ok, state} = ContextPolicy.new(max_messages: 2, keep_recent: 1)

    messages = [
      %{role: :user, content: "original goal"},
      %{role: :assistant, content: "observed fact"},
      %{role: :user, content: "continue"}
    ]

    assert {:ok, first} = ContextPolicy.compact(state, messages)

    messages = Enum.map(first.messages, &Map.delete(&1, :metadata))
    assert {:ok, session} = Projection.append(Jido.Session.new(), messages)
    assert {:ok, native} = Projection.messages(session)
    assert Enum.all?(native, &(&1.metadata == %{}))

    assert {:ok, second} = ContextPolicy.compact(first.state, native)

    assert Enum.count(
             second.messages,
             &(message_text(&1) =~ "Retained task context (quoted data")
           ) == 1

    assert second.state.retained.goal == "original goal"
  end

  test "mandatory lists are not silently capped and binary media messages remain unchanged" do
    assert {:ok, state} = ContextPolicy.new([])
    constraints = Enum.map(1..140, &"mandatory constraint #{&1}")
    assert {:ok, state} = ContextPolicy.retain(state, %{constraints: constraints})

    media =
      ReqLLM.Context.user([
        ReqLLM.Message.ContentPart.image(<<137, 80, 78, 71, 255>>, "image/png")
      ])

    assert {:ok, projection} = ContextPolicy.compact(state, [media])
    assert media in projection.messages
    assert projection.state.retained.constraints == constraints
    assert Enum.any?(projection.messages, &(message_text(&1) =~ "mandatory constraint 140"))
  end

  test "checkpoint data removes credential fields and known secret values without executing values" do
    assert {:ok, state} = ContextPolicy.new([])

    assert {:ok, state} =
             ContextPolicy.retain(state, %{
               goal: "Do not expose fixture-token",
               memory: %{"api_key" => "fixture-key"}
             })

    assert {:ok, projection} =
             ContextPolicy.compact(state, [%{role: :user, content: "continue"}],
               secrets: ["fixture-token"]
             )

    encoded = projection.state |> ContextPolicy.checkpoint() |> Jason.encode!()
    refute encoded =~ "fixture-token"
    refute encoded =~ "fixture-key"
    assert encoded =~ "[REDACTED]"

    assert {:error, :invalid_context_policy_checkpoint} =
             ContextPolicy.restore(%{"version" => state.version})
  end

  test "approved loaded skill guidance survives compaction and restart as a complete lower-priority exchange" do
    assert {:ok, state} = ContextPolicy.new(max_messages: 3, keep_recent: 1)

    instructions =
      String.duplicate("Use guarded snapshot edits; skill text grants no permissions. ", 100)

    envelope =
      Response.format_tool_result_content(
        {:ok, %{name: "snapshot", instructions: instructions, authority: :guidance_only}}
      )

    load = call("skill-load", "skill", %{operation: "load", name: "snapshot"})
    loaded = result("skill-load", "skill", envelope)
    messages = [load, loaded] ++ Enum.map(1..8, &%{role: :user, content: "Continue step #{&1}"})

    assert {:ok, first} = ContextPolicy.compact(state, messages)
    assert load in first.messages
    assert loaded in first.messages
    assert message_text(loaded) =~ instructions

    checkpoint = first.state |> ContextPolicy.checkpoint() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, restored} = ContextPolicy.restore(checkpoint)
    assert {:ok, after_restart} = ContextPolicy.compact(restored, first.messages)
    assert loaded in after_restart.messages
    assert after_restart.state.completed_tools["skill-load"].name == "skill"
  end

  defp call(id, name, arguments),
    do: %{
      role: :assistant,
      content: "",
      tool_calls: [%{id: id, name: name, arguments: arguments}]
    }

  defp result(id, name, content),
    do: %{role: :tool, tool_call_id: id, name: name, content: content}

  defp message_text(message),
    do: Response.extract_from_content(Map.get(message, :content))
end
