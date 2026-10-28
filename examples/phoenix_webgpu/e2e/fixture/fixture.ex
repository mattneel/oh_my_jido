defmodule PhoenixWebGPU.Fixture do
  @moduledoc "Deterministic parent turns; the delegated browser model still uses the real transport."

  alias Jido.AI.Test.ReActScript

  @doc "Makes the parent delegate, receive the structured result, then answer."
  @spec prompt_options(String.t()) :: keyword()
  def prompt_options(text) do
    %{
      user: text,
      turns: [
        %{
          type: :tool_call,
          name: "browser_task",
          arguments: %{
            task: "Read #demo-heading, change it to Browser GPU was here, and report both titles."
          }
        },
        %{
          type: :answer,
          text:
            "The browser child reports: Browser GPU was here. The heading changed in your tab."
        }
      ]
    }
    |> ReActScript.new()
    |> ReActScript.react_opts()
  end
end
