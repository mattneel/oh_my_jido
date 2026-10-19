defmodule OhMyJido.Intelligence.ElixirRename.Bindings do
  @moduledoc false

  @max_items 20_000
  @command "llmEnvironment:oh_my_jido_rename"

  # This fixed, read-only ElixirLS command exposes the parser environment itself.
  # Unlike completion suggestions, it cannot be narrowed by completion plugins
  # or reconstructed default-argument snippets. Coordinates are Elixir's one-based
  # codepoints, not LSP UTF16; Source records the native parser coordinates.
  # The audited 0.31.1 dispatcher accepts any suffix after the command separator;
  # routing remains the already-bound owned Stdio server, never a model field.
  def params(uri, token) do
    %{line: line, column: column} = token.code_position
    %{"command" => @command, "arguments" => ["#{uri}:#{line}:#{column}"]}
  end

  def check(
        %{
          "location" => location,
          "context" => context,
          "imports" => imports,
          "variables" => variables,
          "definitions" => %{"functions_defined" => definitions}
        },
        uri,
        call,
        owner,
        caller,
        %{
          kind: :definition,
          definition_form: definition_form,
          name: function_name,
          arity: function_arity
        },
        destination,
        family_arities
      )
      when is_list(imports) and is_list(variables) and is_list(definitions) and
             length(imports) <= @max_items and length(variables) <= @max_items and
             length(definitions) <= @max_items do
    with true <- authored_caller?(definition_form, function_name, function_arity),
         %{"uri" => ^uri, "line" => line, "column" => column} <- location,
         true <- line == call.code_position.line and column == call.code_position.column,
         %{"module" => module, "function" => function} when is_binary(module) <- context,
         true <- canonical(module) == caller,
         true <- function == "#{function_name}/#{function_arity}",
         {:ok, imported} <- imported(imports),
         {:ok, local} <- definitions(definitions),
         {:ok, visible} <- variables(variables),
         true <- old_available?(imported, local, owner, caller, call, family_arities) do
      occupied = occupied(imported, local, visible, caller, call, destination)

      proof = %{
        native_scope: :parser_environment_imports_locals_and_variables,
        profile: :elixirls_0_31_1_native_environment,
        command: "llmEnvironment",
        context: %{module: caller, function: function},
        imported_mfas: length(imported),
        local_mfas: length(local),
        visible_variables: length(visible)
      }

      {:ok, occupied, proof}
    else
      _ -> {:error, :elixir_rename_native_caller_bindings_incomplete}
    end
  end

  def check(_result, _uri, _call, _owner, _caller, _function, _destination, _arities),
    do: {:error, :elixir_rename_native_caller_bindings_incomplete}

  defp authored_caller?(form, name, arity)
       when form in ["def", "defp"] and is_binary(name) and name != "" and
              is_integer(arity) and arity in 0..255,
       do: true

  defp authored_caller?(_form, _name, _arity), do: false

  defp occupied(imported, local, visible, caller, call, destination) do
    occupied =
      Enum.filter(
        imported ++ local,
        &(&1.name == destination and &1.arity == call.arity and
            (&1.kind == "import" or &1.module == caller))
      )

    if call.kind == :identifier and destination in visible,
      do: [%{module: "$variable", name: destination, arity: 0, kind: "variable"} | occupied],
      else: occupied
  end

  defp old_available?(imports, local, owner, caller, call, arities) do
    Enum.any?(imports, &(&1.module == owner and &1.name == call.name and &1.arity == call.arity)) or
      (owner == caller and
         Enum.any?(local, &(&1.module == owner and &1.name == call.name and &1.arity in arities)))
  end

  defp imported(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      %{"module" => module, "function" => signature}, {:ok, acc}
      when is_binary(module) and is_binary(signature) ->
        case signature(signature) do
          {:ok, name, arity} ->
            {:cont,
             {:ok, [%{module: canonical(module), name: name, arity: arity, kind: "import"} | acc]}}

          :error ->
            {:halt, :error}
        end

      _entry, _acc ->
        {:halt, :error}
    end)
  end

  defp definitions(entries) do
    Enum.reduce_while(entries, {:ok, []}, &definition/2)
  end

  defp definition(entry, {:ok, acc}) when is_binary(entry) do
    case Regex.run(~r/\A(.+)\.([^\/]+)\/(\d{1,3})\z/u, entry) do
      [_, module, name, arity] ->
        case Integer.parse(arity) do
          {arity, ""} when arity in 0..255 ->
            {:cont,
             {:ok, [%{module: canonical(module), name: name, arity: arity, kind: "local"} | acc]}}

          _ ->
            {:halt, :error}
        end

      _ ->
        {:halt, :error}
    end
  end

  defp definition(_entry, _acc), do: {:halt, :error}

  defp variables(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      %{"name" => name, "version" => version}, {:ok, acc}
      when is_binary(name) and is_integer(version) ->
        {:cont, {:ok, [name | acc]}}

      _entry, _acc ->
        {:halt, :error}
    end)
  end

  defp signature(signature) do
    case Regex.run(~r/\A(.+)\/(\d{1,3})\z/u, signature) do
      [_, name, arity] ->
        case Integer.parse(arity) do
          {arity, ""} when arity in 0..255 -> {:ok, name, arity}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp canonical(module), do: String.trim_leading(module, "Elixir.")
end
