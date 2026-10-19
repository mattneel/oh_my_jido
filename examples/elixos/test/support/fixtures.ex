defmodule ElixosHost.Fixtures do
  @moduledoc false

  def context(root, options \\ []) do
    host_opts = Keyword.get(options, :host_opts, [])

    %OhMyJido.Context{
      session_id: Keyword.get(options, :session_id, "fixture-session"),
      runtime: ElixosHost.TestCoding,
      coordinator: Keyword.get(options, :coordinator, self()),
      workspace: root,
      model: "anthropic:claude-sonnet-4-20250514",
      account: "opaque-fixture-account",
      permissions:
        MapSet.new([
          :read,
          :edit,
          :exec,
          :ask,
          :browser,
          :browser_script,
          :network,
          :candidate,
          :deploy,
          :privileges
        ]),
      tools: [OhMyJido.Tools.Read],
      host: {ElixosHost.Host, host_opts}
    }
  end

  def question_id do
    receive do
      {:elixos_ask, [%Elixos.Ask.Question{id: id} | _]} -> id
      {:elixos_ask, []} -> question_id()
    after
      5_000 -> raise "no actual Ask queue question"
    end
  end

  def approve_questions(count) do
    for _ <- 1..count, do: :ok = Elixos.Ask.answer(question_id(), true)
    :ok
  end

  def restore_env(key, {:ok, value}), do: Application.put_env(:elixos, key, value)
  def restore_env(key, :error), do: Application.delete_env(:elixos, key)

  def contains_handle?(term)
      when is_pid(term) or is_port(term) or is_reference(term) or is_function(term), do: true

  def contains_handle?(term) when is_map(term),
    do: Enum.any?(term, fn {key, value} -> contains_handle?(key) or contains_handle?(value) end)

  def contains_handle?(term) when is_list(term), do: Enum.any?(term, &contains_handle?/1)

  def contains_handle?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> contains_handle?()

  def contains_handle?(_term), do: false

  def candidate_source(root) do
    source = Path.join(root, "source/os")
    File.mkdir_p!(Path.join(source, "lib"))
    File.mkdir_p!(Path.join(source, "test/tools"))

    File.write!(Path.join(source, "mix.exs"), """
    defmodule HostCandidateFixture.MixProject do
      use Mix.Project
      def project, do: [app: :host_candidate_fixture, version: "0.1.0", deps: []]
      def application, do: [extra_applications: [:logger]]
    end
    """)

    File.write!(Path.join(source, "lib/sentinel.ex"), """
    defmodule ElixosHost.AuthoredSentinel do
      @on_load :attempt_host_mutation
      def attempt_host_mutation do
        Application.put_env(:elixos, :authored_in_host, true)
        if pid = Process.whereis(ElixosHost.HostProbe), do: send(pid, :authored_host_effect)
        :ok
      end
      def increment(value), do: value + 1
    end
    """)

    File.write!(Path.join(source, "test/sentinel_test.exs"), """
    defmodule HostCandidateFixture.SystemTest do
      use ExUnit.Case
      test "authored function executes in a non-distributed child" do
        assert ElixosHost.AuthoredSentinel.increment(4) == 5
        assert node() == :nonode@nohost
      end
    end
    """)

    File.write!(Path.join(source, "test/tools/smoke_test.exs"), """
    defmodule HostCandidateFixture.ToolTest do
      use ExUnit.Case
      test "tool smoke consumes actual authored behavior" do
        assert ElixosHost.AuthoredSentinel.increment(-1) == 0
      end
    end
    """)

    source
  end
end

defmodule ElixosHost.FixtureNetworkBoundary do
  @moduledoc false
  def authorize(_context, %{operation: :eval, script: "document.title"}, _opts), do: :ok

  def authorize(_context, %{url: url}, _opts) do
    if URI.parse(url).host == "fixture.test", do: :ok, else: {:error, :origin_denied}
  end
end

defmodule ElixosHost.BrowserServiceFixture do
  @moduledoc "Starts the actual Elixos.Browser callbacks at an already-connected, disposable page."

  def child_spec(transport), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [transport]}}
  def start_link(transport), do: :proc_lib.start_link(__MODULE__, :init, [self(), transport])

  def init(parent, transport) do
    true = Process.register(self(), Elixos.Browser)
    page = %CDPEx.Page{browser: transport, conn: transport, target_id: "fixture-page"}
    :proc_lib.init_ack(parent, {:ok, self()})
    # No replacement Browser implementation and no launch/manifest/network path.
    :gen_server.enter_loop(Elixos.Browser, [], %{session: %{}, page: page})
  end
end

defmodule ElixosHost.CDPFixture do
  @moduledoc "A stateful CDP command/lifecycle fixture behind the real CDPEx.Page functions."
  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  def png,
    do:
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=="
      )

  @impl true
  def init(owner),
    do:
      {:ok, %{owner: owner, subscribers: %{}, url: "about:blank", title: "", text: "", held: nil}}

  @impl true
  def handle_call({:subscribe, method, session_id, subscriber}, _from, state) do
    {:reply, :ok,
     %{state | subscribers: Map.put(state.subscribers, {method, subscriber}, session_id)}}
  end

  def handle_call({:unsubscribe, method, subscriber}, _from, state) do
    {:reply, :ok, %{state | subscribers: Map.delete(state.subscribers, {method, subscriber})}}
  end

  def handle_call(
        {:cdp_call, "Page.navigate", %{"url" => url} = params, _timeout, _session},
        from,
        state
      ) do
    send(state.owner, {:cdp_command, "Page.navigate", params})

    if String.ends_with?(url, "/hold") do
      send(state.owner, {:navigation_held, self()})
      {:noreply, %{state | held: {from, url}}}
    else
      state = navigate(state, url)
      {:reply, {:ok, %{"loaderId" => "fixture-loader", "frameId" => "main"}}, state}
    end
  end

  def handle_call(
        {:cdp_call, "Runtime.evaluate", %{"expression" => expression} = params, _timeout,
         _session},
        _from,
        state
      ) do
    send(state.owner, {:cdp_command, "Runtime.evaluate", params})

    value =
      cond do
        expression == "document.title" ->
          state.title

        String.contains?(expression, "location.href") ->
          %{"url" => state.url, "title" => state.title, "content" => state.text}

        String.contains?(expression, "document.querySelector") ->
          state.text

        true ->
          nil
      end

    {:reply, {:ok, %{"result" => %{"value" => value}}}, state}
  end

  def handle_call({:cdp_call, "Page.captureScreenshot", params, _timeout, _session}, _from, state) do
    send(state.owner, {:cdp_command, "Page.captureScreenshot", params})
    {:reply, {:ok, %{"data" => Base.encode64(png())}}, state}
  end

  def handle_call({:cdp_call, method, _params, _timeout, _session}, _from, state),
    do: {:reply, {:error, {:unexpected_fixture_command, method}}, state}

  @impl true
  def handle_info(:release_navigation, %{held: {from, url}} = state) do
    state = navigate(state, url)
    GenServer.reply(from, {:ok, %{"loaderId" => "fixture-loader", "frameId" => "main"}})
    send(state.owner, {:navigation_finished, self()})
    {:noreply, %{state | held: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp navigate(state, url) do
    {title, text} =
      if String.ends_with?(url, "/second"),
        do: {"Fixture second", "Second fixture document"},
        else: {"Fixture first", "First fixture document"}

    for {{"Page.lifecycleEvent", subscriber}, session_id} <- state.subscribers do
      send(
        subscriber,
        {:cdp_event, self(), "Page.lifecycleEvent",
         %{"name" => "networkAlmostIdle", "loaderId" => "fixture-loader", "frameId" => "main"},
         session_id}
      )
    end

    %{state | url: url, title: title, text: text}
  end
end

defmodule ElixosHost.HelperSinkFixture do
  @moduledoc false
  @behaviour Elixos.Shim.Sink
  def open(owner), do: {:ok, owner}

  def write(owner, bytes) do
    send(owner, {:helper_wire, IO.iodata_to_binary(bytes)})
    :ok
  end
end

defmodule ElixosHost.HelperReplyFixture do
  @moduledoc false
  def open(owner) do
    send(owner, {:helper_reader, self()})
    {:ok, owner}
  end

  def read(_owner) do
    receive do
      {:bytes, bytes} -> {:ok, bytes}
      :eof -> :eof
    end
  end

  def close(_owner), do: :ok
end
