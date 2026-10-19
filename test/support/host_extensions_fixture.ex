defmodule OhMyJido.HostExtensionsFixture do
  @moduledoc false

  @behaviour OhMyJido.Host

  @impl true
  def authorize(_context, capability, effect, opts) do
    send(Keyword.fetch!(opts, :owner), {:host_extensions_authorize, capability, effect})
    Keyword.get(opts, :authorization, :ok)
  end

  @impl true
  def credentials(_context, _account, _opts), do: {:error, :credentials_required}

  @impl true
  def question(_context, _question, _opts), do: :pending

  @impl true
  def invoke(context, capability, request, opts) do
    send(Keyword.fetch!(opts, :owner), {:host_extensions_invoke, capability, request})

    case Map.fetch(context.adapters, capability) do
      {:ok, {module, adapter_opts}} -> module.invoke(context, request, adapter_opts)
      :error -> {:error, {:capability_unavailable, capability}}
    end
  end
end

defmodule OhMyJido.HostExtensionsBrowserFixture do
  @moduledoc false

  def invoke(context, %{operation: :navigate} = request, opts) do
    state = Keyword.fetch!(opts, :state)

    Agent.get_and_update(state, fn pages ->
      page_id = Map.get(request, :page_id, "fixture-page")

      page = %{
        owner: context.session_id,
        url: request.url,
        title: "Fixture form",
        value: "",
        submitted: false
      }

      {{:ok, response(page_id, page)}, Map.put(pages, page_id, page)}
    end)
  end

  def invoke(context, %{operation: :close, page_id: page_id}, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :state), fn pages ->
      case Map.fetch(pages, page_id) do
        {:ok, %{owner: owner}} when owner == context.session_id ->
          {{:ok, %{page_id: page_id, closed: true}}, Map.delete(pages, page_id)}

        _ ->
          {{:error, :unknown_page}, pages}
      end
    end)
  end

  def invoke(context, %{page_id: page_id} = request, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :state), fn pages ->
      case Map.fetch(pages, page_id) do
        {:ok, %{owner: owner} = page} when owner == context.session_id ->
          change_page(pages, page_id, page, request)

        _ ->
          {{:error, :unknown_page}, pages}
      end
    end)
  end

  def close_session(context, opts) do
    Agent.update(Keyword.fetch!(opts, :state), fn pages ->
      Map.reject(pages, fn {_id, page} -> page.owner == context.session_id end)
    end)
  end

  defp change_page(pages, page_id, page, request) do
    case change(page, request) do
      {:ok, changed} ->
        {{:ok, response(page_id, changed)}, Map.put(pages, page_id, changed)}

      {:error, reason} ->
        {{:error, reason}, pages}
    end
  end

  defp change(page, %{operation: :snapshot}), do: {:ok, page}

  defp change(page, %{operation: :fill, selector: "#name", value: value}),
    do: {:ok, %{page | value: value}}

  defp change(page, %{operation: :click, selector: "#submit"}),
    do: {:ok, %{page | submitted: true}}

  defp change(_page, _request), do: {:error, :unknown_fixture_element}

  defp response(page_id, page) do
    content = if page.submitted, do: "Submitted #{page.value}", else: "Name: #{page.value}"
    %{page_id: page_id, url: page.url, title: page.title, content: content}
  end
end

defmodule OhMyJido.HostExtensionsResearchFixture do
  @moduledoc false

  def invoke(_context, %{operation: :search, query: query, limit: limit}, opts) do
    pages = Keyword.fetch!(opts, :pages)
    words = query |> String.downcase() |> String.split()

    results =
      pages
      |> Enum.filter(fn {_url, page} ->
        Enum.all?(words, &String.contains?(String.downcase(page.content), &1))
      end)
      |> Enum.take(limit)
      |> Enum.map(fn {url, page} -> %{url: url, title: page.title, snippet: page.content} end)

    {:ok, %{results: results}}
  end

  def invoke(_context, %{operation: :read, url: url}, opts) do
    case Keyword.fetch!(opts, :pages) |> Map.fetch(url) do
      {:ok, page} -> {:ok, Map.put(page, :url, url)}
      :error -> {:error, :fixture_page_not_found}
    end
  end
end

defmodule OhMyJido.HostExtensionsOversizedFixture do
  @moduledoc false

  def invoke(_context, %{operation: :close, page_id: page_id}, _opts) do
    {:ok, %{page_id: page_id, closed: true}}
  end

  def invoke(_context, %{operation: :search}, _opts) do
    {:ok,
     %{
       results:
         Enum.map(1..80, fn i ->
           %{
             url: "https://example.test/#{i}",
             title: String.duplicate("x", 1000),
             snippet: String.duplicate("🦉", 3000)
           }
         end)
     }}
  end

  def invoke(_context, %{operation: :read, url: url}, _opts) do
    {:ok, %{url: url, title: "Read", content: String.duplicate("🦉", 3000)}}
  end

  def invoke(_context, %{operation: :inspect}, _opts) do
    {:ok,
     %{
       media_type: "text/plain",
       summary: String.duplicate("x", 10_000),
       content: String.duplicate("🦉", 3000),
       metadata: Enum.into(1..1000, %{}, &{Integer.to_string(&1), &1})
     }}
  end

  def invoke(_context, _request, _opts) do
    {:ok,
     %{
       page_id: "oversized-page",
       url: "https://example.test/",
       title: "Page",
       content: String.duplicate("🦉", 3000)
     }}
  end
end

defmodule OhMyJido.HostExtensionsReviewFixture do
  @moduledoc false

  def invoke(_context, %{operation: :review, diff: diff}, opts) do
    send(Keyword.fetch!(opts, :owner), {:host_extensions_reviewed_diff, diff})

    {:ok,
     %{
       findings: [
         %{
           path: "change.ex",
           line: Keyword.get(opts, :line, 2),
           category: "dynamic_execution",
           risk: "high",
           message: Keyword.get(opts, :message, "Host noticed runtime code loading"),
           approval_required: true
         },
         %{
           path: "invented.ex",
           line: 900,
           category: "secret",
           risk: "critical",
           message: "Unanchored claim",
           approval_required: true
         }
       ],
       limitations:
         Keyword.get(opts, :limitations, ["Fixture reviewer considers added lines only"])
     }}
  end

  def invoke(_context, %{operation: :diff, workspace: workspace}, _opts) do
    {diff, 0} =
      System.cmd(
        "git",
        ["--no-pager", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--", "."],
        cd: workspace
      )

    {:ok, %{diff: diff, truncated: false, source: :workspace_git}}
  end
end

defmodule OhMyJido.HostExtensionsFailureFixture do
  @moduledoc false

  def invoke(_context, %{operation: :close, page_id: page_id}, _opts),
    do: {:ok, %{page_id: page_id, closed: false}}

  def invoke(_context, _request, opts) do
    if Keyword.get(opts, :uncertain, false),
      do: {:error, %{effect: :uncertain, payload: String.duplicate("do not expose this", 1000)}},
      else: {:error, String.duplicate("untrusted error text", 1000)}
  end
end

defmodule OhMyJido.HostExtensionsReviewOverflowFixture do
  @moduledoc false

  def invoke(context, request, opts) do
    with {:ok, result} <- OhMyJido.HostExtensionsReviewFixture.invoke(context, request, opts) do
      {:ok, %{result | findings: List.duplicate(hd(result.findings), 20)}}
    end
  end
end
