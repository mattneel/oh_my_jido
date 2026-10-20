defmodule OhMyJido.Tools.SkillTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Tools.Skill}

  setup do
    root = Path.join(System.tmp_dir!(), "omj-skills-#{System.unique_integer([:positive])}")
    directory = Path.join(root, ".agents/skills/review-work")
    File.mkdir_p!(directory)

    File.write!(Path.join(directory, "SKILL.md"), """
    ---
    name: review-work
    description: Review a diff with explicit evidence.
    allowed-tools: shell write
    ---
    Keep host safety rules. Review risks before editing.
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    context = %Context{
      session_id: "skills",
      runtime: __MODULE__,
      workspace: root,
      permissions: MapSet.new([:skills]),
      metadata: %{skill_roots: [%{path: ".agents/skills", approved: true}]}
    }

    on_exit(fn -> Skill.clear(context) end)
    %{context: context, root: root}
  end

  test "discovers metadata then strictly loads approved Jido skill instructions without enabling tools",
       %{context: context} do
    assert {:ok, %{skills: [entry]}} = Skill.run(%{operation: "discover"}, %{oh_my_jido: context})
    assert entry.name == "review-work"
    refute Map.has_key?(entry, :instructions)

    assert {:ok, loaded} =
             Skill.run(%{operation: "load", name: "review-work"}, %{oh_my_jido: context})

    assert loaded.instructions =~ "Review risks before editing"
    assert loaded.allowed_tools == ["shell", "write"]
    assert loaded.authority == :guidance_only
    refute Context.permitted?(context, :exec)
    refute Context.permitted?(context, :write)
    refute Context.permitted?(context, :edit)
    assert context.tools == []
  end

  test "the native execution boundary preserves approved skill results without exposing host context",
       %{context: context} do
    context = %{context | tools: [Skill], metadata: Map.put(context.metadata, :private, self())}

    assert {:ok, %{skills: [%{name: "review-work"}], authority: :guidance_only}} =
             OhMyJido.Tool.execute(context, "skill", %{operation: "discover"})

    assert {:ok, loaded} =
             OhMyJido.Tool.execute(context, "skill", %{operation: "load", name: "review-work"})

    assert loaded.name == "review-work"
    assert loaded.instructions =~ "Review risks before editing"
    assert loaded.allowed_tools == ["shell", "write"]
    assert loaded.authority == :guidance_only
    refute Map.has_key?(loaded, :oh_my_jido)
    refute Map.has_key?(loaded, :agent_state)
    refute Map.has_key?(loaded, :private)
    assert context.permissions == MapSet.new([:skills])
    assert context.tools == [Skill]
  end

  test "strict activation rejects a YAML allowed-tools list instead of normalizing it", %{
    context: context,
    root: root
  } do
    path = Path.join(root, ".agents/skills/review-work/SKILL.md")
    File.write!(path, String.replace(File.read!(path), "shell write", "[shell, write]"))

    assert {:error,
            %{
              type: :skill_activation_failed,
              reason: %Jido.AI.Skill.Error.Validation.InvalidField{
                field: :allowed_tools,
                reason: :invalid_type
              }
            }} = Skill.run(%{operation: "load", name: "review-work"}, context)
  end

  test "unapproved roots and missing capability cannot load content", %{context: context} do
    untrusted = put_in(context.metadata.skill_roots, [%{path: ".agents/skills", approved: false}])

    assert {:error, :skill_trust_required} =
             Skill.run(%{operation: "load", name: "review-work"}, untrusted)

    denied = %{context | permissions: MapSet.new()}
    assert {:error, {:permission_denied, :skills}} = Skill.run(%{operation: "discover"}, denied)
  end

  test "does not fall back to the global registry or evaluate project Elixir", %{
    context: context,
    root: root
  } do
    File.write!(Path.join(root, "config.exs"), "raise \"must never execute\"")
    empty = %{context | metadata: %{skill_roots: [], skills: []}}
    assert {:ok, %{skills: []}} = Skill.run(%{operation: "discover"}, empty)

    assert {:error, {:unknown_skill, "review-work"}} =
             Skill.run(%{operation: "load", name: "review-work"}, empty)
  end

  test "inline skills are host-approved and isolated across runtime/workspace namespaces", %{
    context: context
  } do
    spec = %Jido.AI.Skill.Spec{
      name: "inline-review",
      description: "A trusted review policy",
      source: nil,
      body_ref: {:inline, "Preserve approvals."},
      allowed_tools: ["read"]
    }

    approved = %{context | metadata: %{skills: [%{skill: spec, approved: true}]}}

    assert {:ok, %{instructions: "Preserve approvals."}} =
             Skill.run(%{operation: "load", name: "inline-review"}, approved)

    second = %{approved | runtime: __MODULE__.Other, metadata: %{skills: []}}

    assert {:error, {:unknown_skill, "inline-review"}} =
             Skill.run(%{operation: "load", name: "inline-review"}, second)

    untrusted = %{context | metadata: %{skills: [%{skill: spec, approved: false}]}}
    assert {:error, :skill_trust_required} = Skill.run(%{operation: "discover"}, untrusted)
  end
end
