defmodule OhMyJido.Eval.API do
  @moduledoc "The injected `Eval` API inside an Elixir kernel; never evaluates code in the host."

  def tool(name, parameters \\ %{}) when is_binary(name) and is_map(parameters) do
    case request({:tool, name, parameters}) do
      %{"ok" => true, "result" => value} -> value
      %{"ok" => false, "error" => reason} -> raise RuntimeError, reason
      {:error, reason} -> raise RuntimeError, inspect(reason)
    end
  end

  def display(value) do
    text =
      if is_binary(value), do: value, else: inspect(value, limit: 100, printable_limit: 65_536)

    request({:display, text})
  end

  def artifact(name, media_type, data), do: request({:artifact, name, media_type, data})

  defp request(operation), do: :io.request(Process.group_leader(), {:omj_api, operation})
end
