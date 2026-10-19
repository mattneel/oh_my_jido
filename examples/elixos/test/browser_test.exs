defmodule ElixosHost.BrowserTest do
  use ExUnit.Case, async: false

  alias ElixosHost.{Browser, BrowserLease, Fixtures}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    start_supervised!({Elixos.Ask, []})
    start_supervised!({Task.Supervisor, name: ElixosHost.ApprovalTasks})
    start_supervised!({Task.Supervisor, name: ElixosHost.BrowserTasks, max_children: 1})
    transport = start_supervised!({ElixosHost.CDPFixture, self()})
    service = start_supervised!({ElixosHost.BrowserServiceFixture, transport})
    lease = start_supervised!({BrowserLease, task_supervisor: ElixosHost.BrowserTasks})

    options = [
      browser_lease: lease,
      browser_exclusive: true,
      network_boundary: {ElixosHost.FixtureNetworkBoundary, []},
      approval_timeout_ms: 2_000
    ]

    first = Fixtures.context(root, session_id: "first", host_opts: options)
    second = Fixtures.context(root, session_id: "second", host_opts: options)
    {:ok, []} = Elixos.Ask.subscribe()

    %{
      first: first,
      second: second,
      options: options,
      transport: transport,
      service: service,
      lease: lease
    }
  end

  test "real Browser/CDP dispatch navigates, evaluates and captures while another session cannot steal the page",
       context do
    navigation =
      Task.async(fn ->
        Browser.invoke(
          context.first,
          %{
            operation: :navigate,
            url: "https://fixture.test/first",
            timeout_ms: 2_000,
            max_output_bytes: 1024
          },
          context.options
        )
      end)

    Fixtures.approve_questions(2)

    assert {:ok,
            %{
              page_id: page_id,
              content: "First fixture document",
              url: "https://fixture.test/first"
            }} = Task.await(navigation)

    assert_receive {:cdp_command, "Page.navigate", %{"url" => "https://fixture.test/first"}}
    assert_receive {:cdp_command, "Runtime.evaluate", _}

    assert Browser.invoke(
             context.second,
             %{operation: :snapshot, page_id: page_id, timeout_ms: 100, max_output_bytes: 1024},
             context.options
           ) ==
             {:error, :browser_owner_mismatch}

    assert Browser.invoke(
             context.second,
             %{operation: :release, page_id: page_id},
             context.options
           ) ==
             {:error, :browser_owner_mismatch}

    assert Browser.close_session(context.second, context.options) == :ok
    assert Process.alive?(context.service)

    evaluation =
      Task.async(fn ->
        Browser.invoke(
          context.first,
          %{
            operation: :eval,
            page_id: page_id,
            script: "document.title",
            timeout_ms: 2_000,
            max_output_bytes: 1024
          },
          context.options
        )
      end)

    Fixtures.approve_questions(2)
    assert {:ok, %{value: "Fixture first"}} = Task.await(evaluation)
    assert_receive {:cdp_command, "Runtime.evaluate", %{"expression" => "document.title"}}

    assert {:ok, %{mime_type: "image/png", data_base64: png}} =
             Browser.invoke(
               context.first,
               %{
                 operation: :screenshot,
                 page_id: page_id,
                 timeout_ms: 2_000,
                 max_output_bytes: 1024
               },
               context.options
             )

    assert Base.decode64!(png) == ElixosHost.CDPFixture.png()
    assert_receive {:cdp_command, "Page.captureScreenshot", %{"format" => "png"}}

    assert Browser.invoke(context.first, %{operation: :close, page_id: page_id}, context.options) ==
             {:error, :browser_page_close_unavailable}

    assert {:ok, %{released: true, page_closed: false}} =
             Browser.invoke(
               context.first,
               %{operation: :release, page_id: page_id},
               context.options
             )

    assert Process.alive?(context.service)

    navigation =
      Task.async(fn ->
        Browser.invoke(
          context.second,
          %{
            operation: :navigate,
            url: "https://fixture.test/second",
            timeout_ms: 2_000,
            max_output_bytes: 1024
          },
          context.options
        )
      end)

    Fixtures.approve_questions(2)

    assert {:ok, %{page_id: second_page, content: "Second fixture document"}} =
             Task.await(navigation)

    refute second_page == page_id
    assert Process.alive?(context.service)
  end

  test "a deadline never releases an in-flight singleton navigation to another session",
       context do
    navigation =
      Task.async(fn ->
        Browser.invoke(
          context.first,
          %{
            operation: :navigate,
            url: "https://fixture.test/hold",
            timeout_ms: 30,
            max_output_bytes: 1024
          },
          context.options
        )
      end)

    Fixtures.approve_questions(2)
    assert_receive {:navigation_held, transport}
    assert transport == context.transport
    assert {:error, %{effect: :uncertain, reason: :browser_timeout}} = Task.await(navigation)

    assert Browser.invoke(
             context.second,
             %{
               operation: :navigate,
               url: "https://fixture.test/second",
               timeout_ms: 100,
               max_output_bytes: 1024
             },
             context.options
           ) ==
             {:error, :browser_leased}

    assert Browser.close_session(context.first, context.options) ==
             {:error, :browser_operation_pending}

    send(context.transport, :release_navigation)
    assert_receive {:navigation_finished, ^transport}
    assert Process.alive?(context.service)
    assert BrowserLease.owner(context.lease) == {context.first.runtime, context.first.session_id}
  end

  test "a missing network boundary or script grant prevents the actual CDP effect", context do
    assert Browser.invoke(
             context.first,
             %{
               operation: :navigate,
               url: "https://fixture.test/first",
               timeout_ms: 100,
               max_output_bytes: 100
             },
             Keyword.delete(context.options, :network_boundary)
           ) == {:error, :browser_network_boundary_required}

    assert Elixos.Ask.pending() == []
    refute_receive {:cdp_command, "Page.navigate", _}, 20

    read_only = %{
      context.first
      | permissions: MapSet.delete(context.first.permissions, :browser_script)
    }

    navigation =
      Task.async(fn ->
        Browser.invoke(
          read_only,
          %{
            operation: :navigate,
            url: "https://fixture.test/first",
            timeout_ms: 100,
            max_output_bytes: 100
          },
          context.options
        )
      end)

    Fixtures.approve_questions(1)
    assert Task.await(navigation) == {:error, {:permission_denied, :browser_script}}
    refute_receive {:cdp_command, "Page.navigate", _}, 20
  end
end
