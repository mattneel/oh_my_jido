defmodule OhMyJidoDocsWeb.PageControllerTest do
  use OhMyJidoDocsWeb.ConnCase, async: false

  import OhMyJidoDocsWeb.EditorialFixtures

  alias OhMyJidoDocs.Content

  setup do
    configure_operator()
    source_fixture()
  end

  test "the public index links to actually published Markdown", %{conn: conn} do
    index = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    assert index |> LazyHTML.query("#docs-pages a") |> LazyHTML.attribute("href") == [
             "/docs/index"
           ]

    page =
      conn |> recycle() |> get(~p"/docs/index") |> html_response(200) |> LazyHTML.from_document()

    assert page |> LazyHTML.query("#published-document h1") |> LazyHTML.text() ==
             "Published guide"

    assert page |> LazyHTML.query("#published-document") |> LazyHTML.text() =~
             "Original published content."
  end

  test "draft source bodies and unpublished page names are not available to anonymous readers", %{
    conn: conn,
    app: app
  } do
    File.write!(
      Path.join(app, "priv/docs/private-draft.md"),
      "# Confidential draft\n\nDo not publish this.\n"
    )

    stored_run(%{workspace: app, task: "Confidential request"})
    assert conn |> get(~p"/docs/private-draft") |> html_response(404)
    index = conn |> recycle() |> get(~p"/") |> html_response(200)
    refute index =~ "Confidential"
    refute index =~ "private-draft"
    assert conn |> recycle() |> get("/docs/../lib/source") |> response(404)
  end

  test "Markdown is sanitized, never evaluated, and page titles remain escaped", %{
    conn: conn,
    app: app
  } do
    markdown = """
    # <img src=x onerror=alert('title')>

    <script>window.markdown_executed = true</script>
    <img src=x onerror=alert('body')>
    [bad](javascript:alert('link'))

    `{System.cmd("touch", ["/tmp/docs-must-not-execute"])}`
    """

    File.write!(Path.join(app, "priv/docs/unsafe.md"), markdown)

    assert {:ok, _digest} =
             Content.publish_directory(Path.join(app, "priv/docs"), Content.current_digest())

    body = conn |> get(~p"/docs/unsafe") |> html_response(200)
    document = LazyHTML.from_document(body)
    article = LazyHTML.query(document, "#published-document")

    assert Enum.empty?(
             LazyHTML.query(article, "script, [onerror], [onclick], a[href^='javascript:']")
           )

    assert LazyHTML.text(article) =~ "System.cmd"
    assert Enum.empty?(LazyHTML.query(document, "title img"))
    refute body =~ "<script>window.markdown_executed"
  end

  test "public-only mode reads packaged source with no editorial route or mutation", %{
    conn: conn,
    app: app
  } do
    Application.put_env(:oh_my_jido_docs, :editor_enabled, false)

    File.write!(
      Path.join(app, "priv/docs/static.md"),
      "# Static release\n\nRelease-only content.\n"
    )

    page = conn |> get(~p"/docs/static") |> html_response(200) |> LazyHTML.from_document()
    assert page |> LazyHTML.query("#published-document h1") |> LazyHTML.text() == "Static release"
    assert Enum.empty?(LazyHTML.query(page, "a[href='/studio'], a[href='/login']"))
    assert Enum.empty?(LazyHTML.query(page, "script[src], meta[name='csrf-token']"))

    assert {:error, :editor_disabled} =
             Content.publish_directory(Path.join(app, "priv/docs"), nil)

    assert conn |> recycle() |> get(~p"/studio") |> response(404)
  end
end
