defmodule ElixosHost.Tools.Candidate do
  @moduledoc "Host-authored candidate Action registered through OhMyJido.register_tool/2."
  use Jido.Action,
    name: "elixos_candidate",
    description:
      "Build/test a JSON-isolated Elixos candidate or read its evidence. Propose requires a separate deploy grant, host opt-in and human approval; it never acknowledges promotion.",
    schema:
      Zoi.object(%{
        operation: Zoi.enum(["build", "test", "evidence", "provenance", "propose"]),
        path: Zoi.string() |> Zoi.optional(),
        candidate_id: Zoi.string() |> Zoi.optional(),
        phase: Zoi.enum(["build", "test"]) |> Zoi.optional(),
        generation: Zoi.integer() |> Zoi.min(0) |> Zoi.optional()
      })

  def capability, do: :candidate

  @impl true
  def run(params, execution_context) do
    with {:ok, context} <- OhMyJido.Context.fetch(execution_context) do
      request =
        case params.operation do
          "build" ->
            %{operation: :build, path: Map.get(params, :path, ".")}

          "test" ->
            %{operation: :test, candidate_id: Map.get(params, :candidate_id)}

          "propose" ->
            %{operation: :propose, candidate_id: Map.get(params, :candidate_id)}

          "evidence" ->
            %{
              operation: :evidence,
              candidate_id: Map.get(params, :candidate_id),
              phase: if(Map.get(params, :phase, "test") == "build", do: :build, else: :test)
            }

          "provenance" ->
            %{operation: :provenance, generation: Map.get(params, :generation)}
        end

      OhMyJido.Host.call(context, :invoke, [:candidate, request])
    end
  end
end

defmodule ElixosHost.Tools.Browser do
  @moduledoc "Elixos' extra eval/capture surface; shared-browser release is not page close."
  use Jido.Action,
    name: "elixos_browser",
    description:
      "Use the host's singleton browser lease. Navigate/eval require explicit network and script authorization. Release relinquishes only the lease, not the shared native process.",
    schema:
      Zoi.object(%{
        operation: Zoi.enum(["navigate", "snapshot", "eval", "screenshot", "release"]),
        url: Zoi.string() |> Zoi.optional(),
        page_id: Zoi.string() |> Zoi.optional(),
        script: Zoi.string() |> Zoi.optional(),
        timeout_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.max(120_000) |> Zoi.default(15_000),
        max_output_bytes:
          Zoi.integer() |> Zoi.min(1) |> Zoi.max(1_048_576) |> Zoi.default(131_072)
      })

  def capability, do: :browser

  @impl true
  def run(params, execution_context) do
    with {:ok, context} <- OhMyJido.Context.fetch(execution_context) do
      operation =
        case params.operation do
          "navigate" -> :navigate
          "snapshot" -> :snapshot
          "eval" -> :eval
          "screenshot" -> :screenshot
          "release" -> :release
        end

      fields =
        if operation == :release,
          do: [:page_id],
          else: [:url, :page_id, :script, :timeout_ms, :max_output_bytes]

      request = params |> Map.take(fields) |> Map.put(:operation, operation)
      OhMyJido.Host.call(context, :invoke, [:browser, request])
    end
  end
end

defmodule ElixosHost.Tools.Helper do
  @moduledoc "A named helper request; no model-facing command, argv or UID input exists."
  use Jido.Action,
    name: "elixos_helper",
    description:
      "Request exactly one helper allowed by the host and the Elixos shim. Requires the privileges grant and explicit human approval.",
    schema: Zoi.object(%{name: Zoi.string() |> Zoi.min(1) |> Zoi.max(32)})

  def capability, do: :privileges

  @impl true
  def run(params, execution_context) do
    with {:ok, context} <- OhMyJido.Context.fetch(execution_context) do
      OhMyJido.Host.call(context, :invoke, [:privileges, %{name: params.name}])
    end
  end
end
