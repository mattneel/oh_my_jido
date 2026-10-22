defmodule OhMyJido.Intelligence.LSP do
  @moduledoc """
  Reference, host-configured stdio language-server adapter.

  Start under the host supervisor with `context`, `executable` and trusted `args`,
  then bind `context.adapters.lsp` to `{__MODULE__, server: pid}`. The trusted
  adapter option `rename_backend: :elixir` uses source-verified Elixir planning;
  the default `:server` sends `textDocument/rename`. Positions are zero-based
  UTF-16. Rename preview is read-only; application requires snapshots for every
  edited document and the independent `:edit` grant.
  Before publication, the result budget must hold the complete compact success
  receipt, including every path, resulting snapshot and byte count. Optional
  identity and planning metadata need not fit. Partial publication and failed
  synchronization remain typed, non-retryable errors with their actual writes.
  """

  alias OhMyJido.{Files, Tool, Workspace}
  alias OhMyJido.Intelligence.{ElixirRename, Stdio, TextEdits}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 15_000
    }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Stdio.start_link(Keyword.put(opts, :protocol, :lsp))

  @spec invoke(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(context, request, opts) do
    with :ok <- rename_backend(opts),
         server when not is_nil(server) <- Keyword.get(opts, :server),
         {:ok, identity} <- Stdio.bind(server, context) do
      execute(context, server, identity, request, opts)
    else
      nil -> {:error, {:capability_unavailable, :lsp}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Closes the session's language server, given as the trusted `:server` option, at session teardown.

  Returns `:ok` once cleanup of the owned server process group is confirmed or the
  server is already closed, and `{:error, reason}` otherwise.
  """
  @spec close_session(map(), keyword()) :: :ok | {:error, term()}
  defdelegate close_session(context, opts), to: Stdio

  defp execute(context, server, identity, %{operation: :initialize}, opts) do
    params = %{
      "processId" => String.to_integer(System.pid()),
      "rootUri" =>
        "file://" <> URI.encode(context.workspace, &(&1 == ?/ or URI.char_unreserved?(&1))),
      "capabilities" => %{
        "general" => %{"positionEncodings" => ["utf-16"]},
        "workspace" => %{
          "applyEdit" => false,
          "configuration" => true,
          "workspaceEdit" => %{"documentChanges" => true, "resourceOperations" => []}
        },
        "textDocument" => %{"publishDiagnostics" => %{}, "rename" => %{"prepareSupport" => false}}
      },
      "clientInfo" => %{"name" => "oh_my_jido", "version" => "0.1"},
      "workspaceFolders" => [
        %{
          "uri" =>
            "file://" <> URI.encode(context.workspace, &(&1 == ?/ or URI.char_unreserved?(&1))),
          "name" => Path.basename(context.workspace)
        }
      ]
    }

    with {:ok, result} <-
           Stdio.request(server, "initialize", params, Keyword.get(opts, :timeout_ms, 10_000)),
         :ok <- position_encoding(result),
         :ok <- Stdio.notify(server, "initialized", %{}) do
      {:ok, %{capabilities: Map.get(result, "capabilities", %{}), identity: identity}}
    end
  end

  defp execute(context, server, identity, %{operation: operation, path: path} = request, opts)
       when operation in [:open, :change] do
    with {:ok, file} <- Files.read_bytes(context, path),
         false <- file.binary,
         {:ok, uri} <- TextEdits.uri(context, path),
         {:ok, version} <-
           Stdio.document_version(server, uri, operation, Map.get(request, :version)) do
      params =
        if operation == :open do
          %{
            "textDocument" => %{
              "uri" => uri,
              "languageId" => Keyword.get(opts, :language_id, "elixir"),
              "version" => version,
              "text" => file.content
            }
          }
        else
          %{
            "textDocument" => %{"uri" => uri, "version" => version},
            "contentChanges" => [%{"text" => file.content}]
          }
        end

      method = if operation == :open, do: "textDocument/didOpen", else: "textDocument/didChange"

      with :ok <- Stdio.notify(server, method, params) do
        {:ok, %{path: file.path, snapshot: file.snapshot, version: version, identity: identity}}
      end
    else
      true -> {:error, :lsp_binary_document}
      {:error, _} = error -> error
    end
  end

  defp execute(context, server, identity, %{operation: :close_document, path: path}, _opts) do
    with {:ok, uri} <- TextEdits.uri(context, path),
         :ok <-
           Stdio.notify(server, "textDocument/didClose", %{"textDocument" => %{"uri" => uri}}),
         :ok <- Stdio.document_version(server, uri, :close) do
      {:ok, %{closed_document: path, identity: identity}}
    end
  end

  defp execute(context, server, identity, %{operation: :diagnostics, path: path}, _opts) do
    with {:ok, uri} <- TextEdits.uri(context, path),
         {:ok, notification} <- diagnostics(server, uri) do
      {:ok,
       %{
         path: Workspace.relative(context, path),
         diagnostics: get_in(notification, ["params", "diagnostics"]),
         identity: identity,
         source: :server_notification
       }}
    end
  end

  defp execute(context, server, identity, %{operation: operation, path: path} = request, _opts)
       when operation in [:definition, :references, :symbols] do
    with {:ok, uri} <- TextEdits.uri(context, path) do
      params = %{"textDocument" => %{"uri" => uri}}

      params =
        if operation == :symbols, do: params, else: Map.put(params, "position", position(request))

      params =
        if operation == :references,
          do:
            Map.put(params, "context", %{
              "includeDeclaration" => Map.get(request, :include_declaration, true)
            }),
          else: params

      method =
        case operation do
          :definition -> "textDocument/definition"
          :references -> "textDocument/references"
          :symbols -> "textDocument/documentSymbol"
        end

      with {:ok, result} <- Stdio.request(server, method, params) do
        {:ok, %{result: result, identity: identity, trusted: false}}
      end
    end
  end

  defp execute(context, server, identity, %{operation: :rename, path: path} = request, opts) do
    with {:ok, uri} <- TextEdits.uri(context, path),
         {:ok, relative} <- relative_path(context, path),
         {:ok, result, metadata} <- plan_rename(context, server, uri, request, opts),
         snapshots =
           Map.put(Map.get(request, :snapshots, %{}), relative, Map.get(request, :snapshot)),
         {:ok, plans} <- TextEdits.plan(context, result || %{}, snapshots) do
      result =
        cond do
          plans == [] ->
            {:ok, %{applied: false, files: [], reason: :no_edits, identity: identity}}

          Map.get(request, :apply, false) ->
            apply_rename(context, server, identity, plans, opts)

          true ->
            files = Enum.map(plans, &Map.take(&1, [:path, :snapshot, :edits, :version]))
            {:ok, %{applied: false, files: files, identity: identity, trusted: false}}
        end

      rename_result(result, metadata)
    end
  end

  defp execute(context, server, identity, %{operation: :shutdown}, _opts) do
    shutdown = Stdio.request(server, "shutdown", %{})
    Stdio.notify(server, "exit", %{})
    close_result(server, context, identity, shutdown)
  end

  defp execute(_context, _server, _identity, _request, _opts),
    do: {:error, :unsupported_lsp_operation}

  defp rename_backend(opts) do
    case Keyword.get(opts, :rename_backend, :server) do
      backend when backend in [:server, :elixir] -> :ok
      backend -> {:error, {:invalid_lsp_rename_backend, backend}}
    end
  end

  defp plan_rename(context, server, uri, request, opts) do
    case Keyword.get(opts, :rename_backend, :server) do
      :elixir ->
        ElixirRename.plan(context, server, request, opts)

      :server ->
        with {:ok, result} <-
               Stdio.request(server, "textDocument/rename", %{
                 "textDocument" => %{"uri" => uri},
                 "position" => position(request),
                 "newName" => request.new_name
               }) do
          {:ok, result, %{backend: :server, method: "textDocument/rename"}}
        end
    end
  end

  defp rename_result({status, result}, metadata)
       when status in [:ok, :error] and is_map(result) do
    {:ok, backend} = Map.fetch(metadata, :backend)
    {status, Map.merge(result, %{backend: backend, rename_metadata: metadata})}
  end

  defp rename_result(result, _metadata), do: result

  defp apply_rename(context, server, identity, plans, opts) do
    with {:ok, document_versions} <- Stdio.document_versions(server),
         :ok <- rename_receipt_budget(context, plans, opts),
         {:ok, files} <- TextEdits.apply(context, plans, document_versions) do
      case synchronize_edits(context, server, plans, opts) do
        :ok ->
          {:ok, %{applied: true, files: files, identity: identity, effect: :completed}}

        {:error, reason} ->
          {:error,
           %{
             reason: :lsp_rename_sync_failed,
             applied: files,
             failure: reason,
             effect: :completed,
             retry: false
           }}
      end
    else
      {:error, %{applied: [_ | _]} = failure} ->
        {:error, failure |> Map.put_new(:effect, :uncertain) |> Map.put(:retry, false)}

      error ->
        error
    end
  end

  defp rename_receipt_budget(context, plans, opts) do
    maximum = Map.get(context.limits, :extension_result_bytes, 65_536)

    files =
      Enum.map(plans, fn plan ->
        # SHA256 snapshots have fixed JSON width; do not hash the new content twice.
        %{path: plan.path, snapshot: plan.snapshot}
      end)

    receipt = %{
      applied: true,
      files: files,
      effect: :completed,
      backend: Keyword.get(opts, :rename_backend, :server)
    }

    if is_integer(maximum) and IO.iodata_length(Jason.encode_to_iodata!(receipt)) <= maximum,
      do: :ok,
      else: {:error, {:extension_result_limit, :lsp, maximum}}
  end

  defp synchronize_edits(context, server, plans, opts) do
    Enum.reduce_while(plans, :ok, fn plan, :ok ->
      with {:ok, uri} <- TextEdits.uri(context, plan.path),
           {:ok, method, version} <- changed_document(server, uri),
           params = changed_params(method, uri, version, plan.content, opts),
           :ok <- Stdio.notify(server, method, params),
           :ok <- notify_saved(server, uri, opts) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp notify_saved(server, uri, opts) do
    if Keyword.get(opts, :rename_backend, :server) == :elixir do
      # These bytes were actually persisted. ElixirLS rebuilds compiler-backed
      # cross-file identities on save, not on an unsaved buffer change.
      Stdio.notify(server, "textDocument/didSave", %{"textDocument" => %{"uri" => uri}})
    else
      :ok
    end
  end

  defp changed_document(server, uri) do
    case Stdio.document_version(server, uri, :change) do
      {:ok, version} ->
        {:ok, "textDocument/didChange", version}

      {:error, :lsp_document_not_open} ->
        with {:ok, version} <- Stdio.document_version(server, uri, :open),
             do: {:ok, "textDocument/didOpen", version}

      {:error, _} = error ->
        error
    end
  end

  defp changed_params("textDocument/didOpen", uri, version, content, opts),
    do: %{
      "textDocument" => %{
        "uri" => uri,
        "languageId" => Keyword.get(opts, :language_id, "elixir"),
        "version" => version,
        "text" => content
      }
    }

  defp changed_params("textDocument/didChange", uri, version, content, _opts),
    do: %{
      "textDocument" => %{"uri" => uri, "version" => version},
      "contentChanges" => [%{"text" => content}]
    }

  defp position(request),
    do: %{"line" => Map.fetch!(request, :line), "character" => Map.fetch!(request, :character)}

  defp relative_path(context, path) do
    case Workspace.relative(context, path) do
      {:error, _} = error -> error
      relative -> {:ok, relative}
    end
  end

  defp diagnostics(server, uri) do
    selector = %{"uri" => uri}

    case Stdio.latest_event(server, "textDocument/publishDiagnostics", selector) do
      {:error, :event_unavailable} ->
        Stdio.await_event(server, "textDocument/publishDiagnostics", selector)

      result ->
        result
    end
  end

  defp position_encoding(%{"capabilities" => %{"positionEncoding" => encoding}})
       when encoding != "utf-16", do: {:error, {:lsp_position_encoding_unsupported, encoding}}

  defp position_encoding(_result), do: :ok

  defp close_result(server, context, identity, shutdown) do
    shutdown =
      case shutdown do
        {:ok, result} -> %{status: :ok, result: result}
        {:error, reason} -> %{status: :error, reason: inspect(reason)}
      end

    case Stdio.close(server, context) do
      {:ok, result} ->
        {:ok, Map.put(result, :shutdown, shutdown)}

      {:error, :protocol_closed} ->
        {:ok, %{closed: true, cleanup: :owner_cleanup, identity: identity, shutdown: shutdown}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Runs real navigation against a human-supplied server command; never auto-started."
  @spec smoke(map(), keyword(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def smoke(context, server_opts, path, position) do
    with :ok <-
           Tool.authorize(context, :lsp, %{
             operation: :real_server_smoke,
             sensitive: true,
             executable: server_opts[:executable]
           }),
         {:ok, server} <-
           Stdio.start(
             Keyword.merge(server_opts, context: context, owner: self(), protocol: :lsp)
           ) do
      opts = Keyword.put(server_opts, :server, server)

      try do
        with {:ok, initialized} <- invoke(context, %{operation: :initialize}, opts),
             {:ok, opened} <- invoke(context, %{operation: :open, path: path}, opts),
             {:ok, symbols} <- invoke(context, %{operation: :symbols, path: path}, opts),
             {:ok, definition} <-
               invoke(context, Map.merge(position, %{operation: :definition, path: path}), opts),
             {:ok, references} <-
               invoke(context, Map.merge(position, %{operation: :references, path: path}), opts),
             {:ok, diagnostics} <- invoke(context, %{operation: :diagnostics, path: path}, opts) do
          {:ok,
           %{
             initialized: initialized,
             opened: opened,
             symbols: symbols,
             definition: definition,
             references: references,
             diagnostics: diagnostics
           }}
        end
      after
        invoke(context, %{operation: :shutdown}, opts)
        close_session(context, opts)
      end
    end
  end
end
