defmodule OhMyJidoDocs.ContentTest do
  use ExUnit.Case, async: false

  alias OhMyJidoDocs.Content

  setup do
    root = Path.join(System.tmp_dir!(), "docs-content-#{Ecto.UUID.generate()}")

    source = Path.join(root, "source")
    store = Path.join(root, "published")
    File.mkdir_p!(source)
    keys = [:editor_enabled, :published_root, :static_docs_root]
    previous = Map.new(keys, &{&1, Application.fetch_env(:oh_my_jido_docs, &1)})
    Application.put_env(:oh_my_jido_docs, :editor_enabled, true)
    Application.put_env(:oh_my_jido_docs, :published_root, store)
    Application.put_env(:oh_my_jido_docs, :static_docs_root, source)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:oh_my_jido_docs, key, value)
        {key, :error} -> Application.delete_env(:oh_my_jido_docs, key)
      end)

      File.rm_rf!(root)
    end)

    %{root: root, source: source, store: store}
  end

  test "publication captures exact bytes and rejects stale authority", %{source: source} do
    page = Path.join(source, "index.md")
    File.write!(page, "# Reviewed\n\nOriginal body")
    assert {:ok, first} = Content.publish_directory(source, nil)
    File.write!(page, "# Changed\n\nNew draft")

    assert {:ok, %{title: "Reviewed", body: "# Reviewed\n\nOriginal body"}} =
             Content.get_page("index")

    assert {:error, :publication_conflict} = Content.publish_directory(source, nil)
    assert {:ok, second} = Content.publish_directory(source, first)
    refute second == first
    assert {:error, :publication_conflict} = Content.publish_directory(source, first)
    assert {:ok, %{title: "Changed", body: "# Changed\n\nNew draft"}} = Content.get_page("index")
  end

  test "concurrent publishers cannot both spend the same review digest", %{
    root: root,
    source: source
  } do
    File.write!(Path.join(source, "index.md"), "# Initial")
    {:ok, original} = Content.publish_directory(source, nil)

    alternatives =
      for name <- ["alpha", "beta"] do
        path = Path.join(root, name)
        File.mkdir_p!(path)
        File.write!(Path.join(path, "index.md"), "# #{name}")
        path
      end

    results =
      alternatives
      |> Enum.map(fn path -> Task.async(fn -> Content.publish_directory(path, original) end) end)
      |> Enum.map(&Task.await/1)

    assert [{:ok, published}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, :publication_conflict}] = Enum.filter(results, &match?({:error, _}, &1))
    assert Content.current_digest() == published
    assert {:ok, %{title: title}} = Content.get_page("index")
    assert title in ["alpha", "beta"]
  end

  test "authored HTML, unsafe URLs and template expressions never execute", %{
    root: root,
    source: source
  } do
    marker = Path.join(root, "executed")

    body = """
    # Safe heading

    <script>window.stolen = true</script>
    <img src=x onerror=alert(1)>

    [unsafe](javascript:alert(1))

    <%= File.write!(#{inspect(marker)}, "executed") %>
    """

    File.write!(Path.join(source, "index.md"), body)
    assert {:ok, _digest} = Content.publish_directory(source, nil)
    assert {:ok, %{html: html}} = Content.get_page("index")
    assert html =~ "<h1>Safe heading</h1>"
    refute html =~ "<script"
    refute html =~ "onerror="
    refute html =~ "href=\"javascript:"
    refute File.exists?(marker)
  end

  test "unsafe source entries and slugs cannot escape the document root", %{
    root: root,
    source: source
  } do
    File.write!(Path.join(source, "index.md"), "# Index")
    outside = Path.join(root, "outside.md")
    File.write!(outside, "# Private")
    File.ln_s!(outside, Path.join(source, "secret.md"))
    assert {:error, :unsafe_document_entry} = Content.publish_directory(source, nil)
    assert {:error, :not_found} = Content.get_page("../outside")
    assert {:error, :not_found} = Content.get_page("%2e%2e/outside")
    assert {:error, :not_found} = Content.get_page("index\0")
  end

  test "modified snapshots fail closed and cannot be silently reused", %{
    source: source,
    store: store
  } do
    File.write!(Path.join(source, "index.md"), "# Reviewed")
    {:ok, digest} = Content.publish_directory(source, nil)
    File.write!(Path.join([store, "snapshots", digest, "index.md"]), "# Tampered")
    assert {:error, :not_found} = Content.get_page("index")
    assert Content.list_pages() == []
    assert {:error, :snapshot_modified} = Content.publish_directory(source, digest)
  end

  test "public mode only reads packaged documentation and refuses mutation", %{
    source: source,
    store: store
  } do
    File.write!(Path.join(source, "index.md"), "# Release content")
    Application.put_env(:oh_my_jido_docs, :editor_enabled, false)
    assert :ok = Content.bootstrap!()
    assert {:ok, %{title: "Release content"}} = Content.get_page("index")
    assert {:error, :editor_disabled} = Content.publish_directory(source, nil)
    refute File.exists?(store)
  end

  test "repeated Markdown extensions cannot alias a reviewed slug", %{source: source} do
    File.write!(Path.join(source, "index.md"), "# Reviewed")
    {:ok, current} = Content.publish_directory(source, nil)
    File.write!(Path.join(source, "index.md.md"), "# Hidden collision")
    assert {:error, :invalid_document} = Content.publish_directory(source, current)
    assert {:ok, %{title: "Reviewed"}} = Content.get_page("index")
  end

  test "empty directory breadth consumes the global inventory budget", %{source: source} do
    File.write!(Path.join(source, "index.md"), "# Reviewed")
    for index <- 1..1_025, do: File.mkdir!(Path.join(source, "directory-#{index}"))
    assert {:error, :document_entry_limit} = Content.publish_directory(source, nil)
    assert Content.current_digest() == nil
  end

  test "an oversized replacement cannot change already reviewed bytes", %{source: source} do
    path = Path.join(source, "index.md")
    reviewed = "# Reviewed\n" <> String.duplicate("x", 262_133)
    File.write!(path, reviewed)
    {:ok, current} = Content.publish_directory(source, nil)
    File.write!(path, reviewed <> "x")
    assert {:error, _reason} = Content.publish_directory(source, current)
    assert {:ok, %{body: ^reviewed}} = Content.get_page("index")
  end
end
