defmodule OhMyJidoBrowser.HTML do
  @moduledoc "HTML escaping for text that comes from people, tools or the model."

  @doc "Escapes text for HTML element content and quoted attribute values."
  @spec escape(String.Chars.t()) :: String.t()
  def escape(value) do
    value
    |> to_string()
    |> String.replace(["&", "<", ">", "\"", "'"], fn
      "&" -> "&amp;"
      "<" -> "&lt;"
      ">" -> "&gt;"
      "\"" -> "&quot;"
      "'" -> "&#39;"
    end)
  end
end
