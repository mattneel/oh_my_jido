if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.OhMyJido.Install do
    @shortdoc "Previews source-checkout dependency setup (apply with --apply --yes)"
    @moduledoc """
    Sets up a consumer's top-level patched source dependencies with native Igniter.

        mix oh_my_jido.install --source /absolute/oh_my_jido --dry-run
        mix oh_my_jido.install --source /absolute/oh_my_jido --apply --yes

    `--snakepit` explicitly includes the patched Python backend dependency with
    `runtime: false`; it does not install Python or start workers. Only `mix.exs`
    changes. No supervision, grants, credentials, or application config is added.

    This task is for an already-resolved project. Like every Mix invocation, it
    follows Mix's normal target project and configuration loading before task
    dispatch. The installer itself never cross-loads or evaluates target code.
    Use the standalone bootstrap when target evaluation must be avoided.

    Native `igniter.install` fetches and compiles packages before their install
    callbacks, and Mix overrides are not transitive. For initial source-checkout
    installation, run the bootstrap from the consumer directory before `mix deps.get`:

        elixir /absolute/oh_my_jido/priv/oh_my_jido/install.exs --dry-run
        elixir /absolute/oh_my_jido/priv/oh_my_jido/install.exs --apply --yes

    The bootstrap may fetch its pinned Igniter tooling on first use. It never
    compiles the consumer graph, reads credentials, or makes provider requests.
    """

    if Code.ensure_loaded?(Boundary) do
      Code.eval_quoted(
        quote do
          use Boundary, classify_to: OhMyJido.Install
        end,
        [],
        __ENV__
      )
    end

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        schema: [source: :string, snakepit: :boolean, apply: :boolean],
        required: [:source],
        example: "--source /absolute/oh_my_jido --dry-run"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      OhMyJido.Install.plan(igniter, Keyword.take(igniter.args.options, [:source, :snakepit]))
    end

    # Skip the native default's pre-plan compilation, not the ordinary Mix CLI
    # project/config loading that has already happened before task dispatch.
    @impl Mix.Task
    def run(argv) do
      case OhMyJido.Install.run(argv) do
        {:ok, _result} -> :ok
        {:error, message} -> Mix.raise(message)
      end
    end
  end
else
  defmodule Mix.Tasks.OhMyJido.Install do
    @shortdoc "Explains source-checkout bootstrap when optional Igniter is absent"
    @moduledoc "See `OhMyJido.Install` for source-checkout setup before dependency resolution."

    if Code.ensure_loaded?(Boundary) do
      Code.eval_quoted(
        quote do
          use Boundary, classify_to: OhMyJido.Install
        end,
        [],
        __ENV__
      )
    end

    use Mix.Task

    @impl Mix.Task
    def run(argv) do
      {:error, message} = OhMyJido.Install.run(argv)
      Mix.raise(message)
    end
  end
end
