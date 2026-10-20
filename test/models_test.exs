defmodule OhMyJido.ModelsTest do
  use ExUnit.Case, async: true

  alias OhMyJido.Models

  test "all six roles resolve through installed Jido model aliases" do
    roles = [:coding, :planning, :exploration, :review, :advisor, :compaction]

    mappings =
      Map.new(roles, &{&1, if(&1 in [:exploration, :compaction], do: :fast, else: :capable)})

    assert Models.roles() == roles

    for role <- roles do
      assert {:ok, selection} = Models.select([role: role], %{model_roles: mappings})
      assert selection.role == role
      assert selection.model == Jido.AI.Models.resolve(mappings[role])
      assert selection.source == :default
    end
  end

  test "explicit, session, approved project, user and default selection have strict precedence" do
    defaults = model("default")
    user = model("user")
    project = model("project")
    session = model("session")
    explicit = model("explicit")

    config = %{
      model_roles: %{coding: defaults},
      user_config: %{model_roles: %{coding: user}},
      project_config: %{model_roles: %{coding: project}},
      project_approved: true
    }

    assert {:ok, %{model: ^explicit, source: :explicit, account: "account-explicit"}} =
             Models.select(
               %{
                 model: explicit,
                 account: "account-explicit",
                 session_selection: %{model: session}
               },
               config
             )

    assert {:ok, %{model: ^session, source: :session}} =
             Models.select(%{session_selection: %{model: session}}, config)

    assert {:ok, %{model: ^project, source: :project}} = Models.select(%{}, config)

    assert {:ok, %{model: ^user, source: :user}} =
             Models.select(%{}, Map.put(config, :project_approved, false))

    assert {:ok, %{model: ^defaults, source: :default}} =
             Models.select(%{}, Map.drop(config, [:project_config, :user_config]))
  end

  test "each layer falls through only for missing role entries, not invalid selected models" do
    config = %{
      model_roles: %{review: :capable},
      user_config: %{model_roles: %{coding: :fast}},
      project_config: %{model_roles: %{planning: :capable}},
      project_approved: true
    }

    assert {:ok, %{role: :review, source: :default}} = Models.select([role: :review], config)

    assert {:error, :invalid_model} =
             Models.select([model: :nonexistent_oh_my_jido_alias], config)

    assert {:error, :invalid_model} = Models.select([model: "not-a-provider-model"], config)
    assert {:error, :invalid_role} = Models.select([role: "make_new_atoms"], config)
  end

  test "changing a role does not pin the previous role's retained model" do
    coding = model("coding")
    planning = model("planning")
    config = %{model_roles: %{coding: coding, planning: planning}}
    assert {:ok, saved} = Models.select([role: :coding, account: "selected-account"], config)

    assert {:ok,
            %{role: :planning, model: ^planning, account: "selected-account", source: :default}} =
             Models.select([role: :planning, session_selection: saved], config)
  end

  test "role configuration supports declarative string keys and independently selected accounts" do
    config = %{
      "default_role" => "review",
      "model_roles" => %{"review" => %{"model" => model("review"), "account" => "review-account"}}
    }

    assert {:ok, %{role: :review, account: "review-account"}} = Models.select(%{}, config)

    assert {:ok, %{account: "session-account"}} =
             Models.select([account: "session-account"], config)
  end

  test "account selections are opaque durable references, not raw credential maps" do
    reference = {:host_account, "opaque-registration"}
    assert {:ok, %{account: ^reference}} = Models.select([account: reference], %{})

    assert {:error, :invalid_account_reference} =
             Models.select([account: %{api_key: "never-retain-this"}], %{})

    assert {:error, :invalid_account_reference} = Models.select([account: self()], %{})
    assert {:error, :invalid_account_reference} = Models.select([account: ""], %{})
  end

  test "credential-bearing model inputs and nested request options are refused" do
    assert {:error, :credentials_must_come_from_host} =
             Models.resolve({:openai, "gpt-4", api_key: "fixture-imported-key"})

    assert {:error, :credentials_must_come_from_host} =
             Models.select(
               [
                 model: %{
                   id: "inline",
                   provider: :openai,
                   extra: %{access_token: "fixture-imported-token"}
                 }
               ],
               %{}
             )

    assert Models.credential_options?(
             llm_opts: [
               provider_options: [openai: [auth_mode: :oauth, oauth_file: "/not-read/auth.json"]]
             ]
           )

    assert Models.credential_options?(
             req_http_options: [headers: [{"authorization", "Bearer fixture-token"}]]
           )

    refute Models.credential_options?(
             llm_opts: [temperature: 0.2, provider_options: [store: false]]
           )
  end

  test "project overrides require a host approval, and even approved scripts are never evaluated" do
    path = Path.join(System.tmp_dir!(), "omj-untrusted-#{System.unique_integer([:positive])}.exs")
    File.write!(path, "send(self(), :project_config_executed); %{model_roles: %{coding: :fast}}")
    on_exit(fn -> File.rm(path) end)

    config = %{model_roles: %{coding: :capable}, project_config: path}
    assert {:ok, %{source: :default}} = Models.select(%{}, config)

    assert {:error, :project_config_must_be_declarative} =
             Models.select(%{}, Map.put(config, :project_approved, true))

    refute_receive :project_config_executed

    assert {:error, :project_config_must_be_declarative} =
             Models.select(%{}, %{
               project_config: %{model_roles: %{coding: fn -> :fast end}},
               project_approved: true
             })
  end

  defp model(id), do: %{id: id, provider: :openai, capabilities: %{tools: %{enabled: true}}}
end
