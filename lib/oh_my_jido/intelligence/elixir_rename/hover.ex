defmodule OhMyJido.Intelligence.ElixirRename.Hover do
  @moduledoc false

  alias OhMyJido.Intelligence.ElixirRename.Source

  # ElixirLS emits this declaration preamble itself, before the untrusted
  # documentation body (Providers.Hover.format_doc/1). Never search that body
  # for a kind marker: documentation can contain a counterfeit example.
  # initialize.serverInfo confirms the supported formatter, not authentication;
  # the executable and transport remain the host's trusted configuration.
  @preamble ~r/\A```elixir\r?\n(.*?)\r?\n```\r?\n\r?\n\*(function|macro)\*(?:\s|\z)/s
  @max_preamble_bytes 16_384

  def callable(
        %{"contents" => %{"kind" => "markdown", "value" => markdown}, "range" => range},
        token,
        source
      )
      when is_binary(markdown) do
    prefix = binary_part(markdown, 0, min(byte_size(markdown), @max_preamble_bytes))

    with [_, signature, kind] <- Regex.run(@preamble, prefix),
         true <- String.valid?(signature),
         {:ok, {{dot, _dot_meta, [receiver, name]}, _meta, arguments}} <-
           Code.string_to_quoted(signature,
             static_atoms_encoder: fn value, _meta -> {:ok, value} end,
             emit_warnings: false
           ),
         true <-
           Source.word(dot) == "." and Source.word(name) == token.name and is_list(arguments),
         true <- compatible_arity?(arguments, token.arity),
         module when is_binary(module) <- module_name(receiver),
         %{"start" => first, "end" => last} <- range,
         {:ok, start} <- Source.offset(source, first),
         {:ok, ending} <- Source.offset(source, last),
         true <- start <= token.start and ending >= token.end do
      {:ok, %{kind: kind, module: module, name: token.name, arity: token.arity, range: range}}
    else
      _ -> {:error, :elixir_rename_unverified_native_callable_kind}
    end
  end

  def callable(_hover, _token, _source),
    do: {:error, :elixir_rename_unverified_native_callable_kind}

  defp compatible_arity?(arguments, arity) do
    defaults =
      Enum.count(arguments, fn
        {operator, _meta, _arguments} -> Source.word(operator) == "\\\\"
        _argument -> false
      end)

    arity >= length(arguments) - defaults and arity <= length(arguments)
  end

  defp module_name({aliases, _meta, parts}) when aliases in [:__aliases__, "__aliases__"] do
    if Enum.all?(parts, &(is_atom(&1) or is_binary(&1))),
      do: parts |> Enum.map_join(".", &Source.word/1) |> String.trim_leading("Elixir.")
  end

  defp module_name(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  defp module_name(atom) when is_binary(atom), do: atom
  defp module_name(_dynamic), do: nil
end
