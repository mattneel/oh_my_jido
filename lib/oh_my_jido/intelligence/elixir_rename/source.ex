defmodule OhMyJido.Intelligence.ElixirRename.Source do
  @moduledoc false

  @runtime_operators ~w(+ - * / ++ -- <> == != === !== < > <= >= =~ ! && || &&& ||| ^^^ ~~~ <<< >>>)
  @runtime_apis %{
    "capture" => %{"Function" => {:dynamic_dispatch, [3]}},
    "concat" => %{"Module" => {:dynamic_module, [1, 2]}},
    "safe_concat" => %{"Module" => {:dynamic_module, [1, 2]}},
    "create" => %{"Module" => {:dynamic_module, [3]}},
    "eval_string" => %{"Code" => {:dynamic_module, [1, 2, 3]}},
    "eval_quoted" => %{
      "Code" => {:dynamic_module, [1, 2, 3]},
      "Module" => {:dynamic_module, [2, 3, 4]}
    },
    "compile_string" => %{"Code" => {:dynamic_module, [1, 2]}},
    "compile_quoted" => %{"Code" => {:dynamic_module, [1, 2]}},
    "compile_file" => %{"Code" => {:dynamic_module, [1, 2]}},
    "require_file" => %{"Code" => {:dynamic_module, [1, 2]}}
  }

  # This is a source index, not an Elixir expander. In particular, aliases never
  # establish semantic identity here; the native provider must corroborate them.
  def parse(file) do
    table = :ets.new(__MODULE__, [:ordered_set, :private])

    try do
      encoder = fn name, meta ->
        :ets.insert(table, {{meta[:line], meta[:column]}, name})
        {:ok, name}
      end

      case Code.string_to_quoted(file.content,
             columns: true,
             token_metadata: true,
             static_atoms_encoder: encoder,
             literal_encoder: fn value, meta -> {:ok, {:__literal__, meta, [value]}} end,
             emit_warnings: false
           ) do
        {:ok, ast} ->
          source = Map.merge(file, %{lines: lines(file.content), raw: :ets.tab2list(table)})

          env = %{
            module: nil,
            module_name: nil,
            function: nil,
            scope: [],
            aliases: %{},
            attribute: nil
          }

          state = %{source: source, tokens: [], imports: [], hazards: []}

          state =
            Enum.reduce(source.raw, state, fn {_position, value}, state ->
              if String.starts_with?(value, "Elixir."),
                do:
                  hazard(
                    state,
                    :literal_module_identity,
                    String.trim_leading(value, "Elixir."),
                    env
                  ),
                else: state
            end)

          {state, _env} = walk(ast, env, state)

          {:ok,
           Map.merge(Map.delete(source, :raw), %{
             tokens: state.tokens |> Enum.reverse() |> Enum.uniq_by(&key/1),
             imports: Enum.reverse(state.imports),
             hazards: Enum.reverse(state.hazards)
           })}

        {:error, reason} ->
          {:error, {:elixir_rename_parse_error, file.path, inspect(reason)}}
      end
    rescue
      error in [ArgumentError, FunctionClauseError, MatchError] ->
        {:error, {:elixir_rename_source_metadata, file.path, Exception.message(error)}}
    after
      :ets.delete(table)
    end
  end

  def key(token), do: {token.path, token.start, token.end, token.kind}
  def word({:__literal__, _meta, [value]}), do: word(value)
  def word(value) when is_atom(value), do: Atom.to_string(value)
  def word(value) when is_binary(value), do: value
  def word(_value), do: nil

  def position(source, line, column) when is_integer(line) and is_integer(column) do
    with true <- line > 0 and column > 0,
         {offset, text} when is_binary(text) <- fetch_line(source, line - 1),
         {:ok, bytes, units} <- codepoint_prefix(text, column - 1, 0, 0) do
      {:ok, offset + bytes, %{"line" => line - 1, "character" => units}}
    else
      _ -> {:error, :elixir_rename_invalid_source_position}
    end
  end

  def position(_source, _line, _column), do: {:error, :elixir_rename_invalid_source_position}

  def offset(source, %{"line" => line, "character" => character})
      when is_integer(line) and line >= 0 and is_integer(character) and character >= 0 do
    with {base, text} when is_binary(text) <- fetch_line(source, line),
         {:ok, bytes} <- utf16_offset(text, character, 0) do
      {:ok, base + bytes}
    else
      _ -> {:error, :elixir_rename_invalid_provider_position}
    end
  end

  def offset(_source, _position), do: {:error, :elixir_rename_invalid_provider_position}

  def at(source, position) do
    with {:ok, offset} <- offset(source, position) do
      candidates = Enum.filter(source.tokens, &(offset >= &1.start and offset < &1.end))

      case Enum.sort_by(candidates, &{&1.end - &1.start, priority(&1.kind)}) do
        [token | _] -> {:ok, token}
        [] -> {:error, :elixir_rename_identifier_required}
      end
    end
  end

  # ElixirLS may return a whole authored definition head, or a zero-width module
  # anchor. Those are evidence coordinates, never replacement ranges.
  def anchored(source, %{"start" => first, "end" => last}) do
    with {:ok, start} <- offset(source, first),
         {:ok, ending} <- offset(source, last),
         true <- ending >= start do
      matches = anchored_tokens(source.tokens, start, ending)

      case Enum.uniq_by(matches, &key/1) do
        [token] -> {:ok, token}
        [] -> {:error, :elixir_rename_unauthored_provider_location}
        _ -> {:error, :elixir_rename_ambiguous_provider_location}
      end
    else
      _ -> {:error, :elixir_rename_invalid_provider_range}
    end
  end

  def anchored(_source, _range), do: {:error, :elixir_rename_invalid_provider_range}

  defp anchored_tokens(tokens, start, ending) do
    declarations = Enum.filter(tokens, &anchored_declaration?(&1, start, ending))
    preferred_anchor(declarations, tokens, start, ending)
  end

  defp anchored_declaration?(token, start, ending) do
    token.kind in [:definition, :module_definition] and
      (token.declaration_start == start or (token.start >= start and token.end <= ending))
  end

  defp preferred_anchor([_ | _] = declarations, _tokens, start, _ending) do
    case Enum.filter(declarations, &(&1.declaration_start == start)) do
      [] -> declarations
      exact -> exact
    end
  end

  defp preferred_anchor([], tokens, start, ending) do
    statements = Enum.filter(tokens, &statement_anchor?(&1, start, ending))

    case statements do
      [] -> Enum.filter(tokens, &within_anchor?(&1, start, ending))
      _ -> statements
    end
  end

  defp statement_anchor?(%{kind: :module, declaration_start: start}, start, _ending), do: true

  defp statement_anchor?(
         %{call_form: :spec_head, declaration_start: start} = token,
         start,
         ending
       ),
       do: token.end <= ending

  defp statement_anchor?(_token, _start, _ending), do: false

  defp within_anchor?(token, start, ending) do
    (start >= token.start and start < token.end) or
      (token.start >= start and token.end <= ending and ending > start)
  end

  defp priority(:definition), do: 0
  defp priority(:module_definition), do: 0
  defp priority(_kind), do: 1

  defp walk({form, _meta, nil} = ast, env, state)
       when (is_atom(form) or is_binary(form)) and
              form not in [
                :__MODULE__,
                "__MODULE__",
                :__ENV__,
                "__ENV__",
                :__CALLER__,
                "__CALLER__"
              ] do
    call(ast, env, state, 0)
  end

  defp walk({form, meta, _args} = ast, env, state) when is_list(meta),
    do: walk_form(word(form), ast, env, state)

  defp walk(list, env, state) when is_list(list), do: children(list, env, state)
  defp walk({left, right}, env, state), do: children([left, right], env, state)
  defp walk(_literal, env, state), do: {state, env}

  defp walk_form("__literal__", {_form, _meta, args}, env, state),
    do: children(args, env, state)

  defp walk_form("__block__", {_form, _meta, args}, env, state),
    do: block(args, env, state)

  defp walk_form("defmodule", {_form, meta, args}, env, state),
    do: module(args, meta, env, state)

  defp walk_form(form, {_form, meta, args}, env, state) when form in ["def", "defp"],
    do: definition(args, meta, form, env, state)

  defp walk_form(form, {_form, meta, args} = ast, env, state)
       when form in ["defmacro", "defmacrop", "defguard", "defguardp", "defdelegate"] do
    {state, _} = definition(args, meta, form, env, state)
    {hazard(state, :generated_definition, ast, env), env}
  end

  defp walk_form("__aliases__", ast, env, state),
    do: {add_alias(ast, :reference, env, state), env}

  defp walk_form("__MODULE__", {_form, meta, _args}, env, state),
    do: {put_identifier(state, "__MODULE__", meta, :module_self, env, %{}), env}

  defp walk_form(form, ast, env, state) when form in ["__ENV__", "__CALLER__"],
    do: {hazard(state, :lexical_introspection, ast, env), env}

  defp walk_form("alias", {_form, meta, args}, env, state),
    do: alias_directive(args, meta, env, state)

  defp walk_form("import", {_form, meta, args}, env, state),
    do: import_directive(args, meta, env, state)

  defp walk_form("use", {_form, _meta, args} = ast, env, state),
    do: children(args, env, hazard(state, :opaque_use, ast, env))

  defp walk_form("require", {_form, meta, args}, env, state) do
    if is_list(args) and keyword(Enum.at(args, 1), "as") != nil,
      do: alias_directive(args, meta, env, state),
      else: require_directive(args, meta, env, state)
  end

  defp walk_form("quote", ast, env, state),
    do: {hazard(state, quote_reason(ast), ast, env), env}

  defp walk_form(form, ast, env, state) when form in ["unquote", "unquote_splicing"],
    do: {hazard(state, :generated_code, ast, env), env}

  defp walk_form("|>", {_form, _meta, args}, env, state), do: pipe(args, env, state)
  defp walk_form("&", {_form, _meta, args}, env, state), do: capture(args, env, state)
  defp walk_form("@", {_form, meta, args}, env, state), do: attribute(args, meta, env, state)

  defp walk_form("defoverridable", ast, env, state),
    do: {hazard(state, :compiler_attribute, ast, env), env}

  defp walk_form(form, {_form, meta, args}, env, state)
       when form in ["fn", "for", "with", "case", "cond", "receive", "try", "->"] do
    nested = %{env | scope: env.scope ++ [{form, meta[:line], meta[:column]}]}
    {state, _} = children(args, nested, state)
    {state, env}
  end

  defp walk_form(form, ast, env, state)
       when form in ["apply", "function_exported?", "macro_exported?", "defimpl", "defprotocol"],
       do: dynamic_call(ast, env, state)

  defp walk_form(form, {_form, _meta, [_, _, _ | _] = args} = ast, env, state)
       when form in ["spawn", "spawn_link", "spawn_monitor", "spawn_opt"] and is_list(args),
       do: dynamic_call(ast, env, state)

  defp walk_form(form, ast, env, state) when is_binary(form) do
    state =
      if String.starts_with?(form, "sigil_"),
        do: hazard(state, :opaque_sigil, ast, env),
        else: state

    call(ast, env, state, 0)
  end

  defp walk_form(_form, ast, env, state), do: call(ast, env, state, 0)

  defp dynamic_call(ast, env, state) do
    {state, _} = call(ast, env, hazard(state, :dynamic_dispatch, ast, env), 0)
    {state, env}
  end

  defp quote_reason(ast) do
    generated =
      Enum.any?(
        names(ast, []),
        &(&1 in [
            "unquote",
            "unquote_splicing",
            "defmodule",
            "def",
            "defp",
            "defmacro",
            "defmacrop",
            "__MODULE__",
            "__ENV__",
            "__CALLER__"
          ])
      )

    if generated, do: :generated_code, else: :quoted_code
  end

  defp attribute([{name, _meta, args} = attribute], meta, env, state) do
    state =
      cond do
        word(name) in [
          "compile",
          "on_load",
          "on_definition",
          "before_compile",
          "after_compile",
          "after_verify"
        ] ->
          hazard(state, :compiler_attribute, attribute, env)

        word(name) == "behaviour" ->
          hazard(state, :behaviour_contract, attribute, env)

        true ->
          state
      end

    attribute_env = %{env | attribute: word(name)}

    {state, _attribute_env} =
      if word(name) == "spec" and module_scope?(env),
        do: specification(args, meta, attribute_env, state),
        else: children(args, attribute_env, state)

    {state, env}
  end

  defp attribute(args, _meta, env, state), do: children(args, env, state)

  defp module_scope?(env) do
    env.module != nil and env.function == nil and List.last(env.scope) == env.module and
      Enum.all?(env.scope, &match?({_path, _start}, &1))
  end

  defp specification([ast], meta, env, state) do
    {signature, constraints} = head(ast)
    {state, _} = signature(signature, meta, env, state)
    children(constraints, env, state)
  end

  defp specification(args, _meta, env, state), do: children(args, env, state)

  # Only the declaration head is a function occurrence. Its argument and return
  # types keep their own native identities and never inherit runtime exemptions.
  defp signature({form, _meta, [{name, meta, args}, result]} = ast, declaration_meta, env, state)
       when form in [:"::", "::"] and (is_atom(name) or is_binary(name)) and is_list(meta) and
              is_list(args) do
    if identifier_name?(word(name)) do
      state =
        put_identifier(state, word(name), meta, :call, env, %{
          arity: length(args),
          call_form: :spec_head,
          declaration_start: meta_offset(state, declaration_meta)
        })

      {state, _} = children(args, env, state)
      walk(result, env, state)
    else
      walk(ast, env, state)
    end
  end

  defp signature(ast, _meta, env, state), do: walk(ast, env, state)

  defp block(nodes, env, state) when is_list(nodes) do
    Enum.reduce(nodes, {state, env}, fn node, {state, env} -> walk(node, env, state) end)
  end

  defp block(_nodes, env, state), do: {state, env}

  defp children(nodes, env, state) when is_list(nodes) do
    state = Enum.reduce(nodes, state, fn node, state -> elem(walk(node, env, state), 0) end)
    {state, env}
  end

  defp children(_nodes, env, state), do: {state, env}

  defp module([module_ast, body], meta, env, state) do
    state =
      if env.function != nil, do: hazard(state, :dynamic_module, module_ast, env), else: state

    case alias_token(module_ast, :module_definition, env, state.source) do
      {:ok, token} ->
        id = {token.path, token.start}

        module_name =
          if env.module_name && not String.contains?(token.name, "."),
            do: env.module_name <> "." <> token.name,
            else: String.trim_leading(token.name, "Elixir.")

        token =
          Map.merge(token, %{
            kind: :module_definition,
            module: id,
            declaration_start: meta_offset(state, meta),
            module_name: module_name
          })

        nested = %{
          env
          | module: id,
            module_name: module_name,
            function: nil,
            scope: env.scope ++ [id]
        }

        state = add(state, token)

        state =
          if token.alias_binding, do: hazard(state, :dynamic_module, module_ast, env), else: state

        {state, _} = walk(keyword(body, "do"), nested, state)
        {state, env}

      {:error, _} ->
        {hazard(state, :dynamic_module, module_ast, env), env}
    end
  end

  defp module(args, _meta, env, state), do: {hazard(state, :dynamic_module, args, env), env}

  defp definition([head | rest], meta, form, env, state) do
    {head, guards} = head(head)

    case head do
      {name, head_meta, args} when (is_atom(name) or is_binary(name)) and is_list(head_meta) ->
        args = if is_list(args), do: args, else: []
        arity = length(args)
        defaults = Enum.count(args, &default?/1)
        function = {state.source.path, meta_offset(state, head_meta)}
        nested = %{env | function: function, scope: env.scope ++ [function]}

        state =
          put_identifier(state, word(name), head_meta, :definition, nested, %{
            arity: arity,
            arities: Enum.to_list((arity - defaults)..arity),
            declaration_start: meta_offset(state, meta),
            definition_form: form,
            public: form == "def"
          })

        {state, _} = children(args ++ guards ++ rest, nested, state)
        {state, env}

      _ ->
        {hazard(state, :generated_definition, head, env), env}
    end
  end

  defp definition(args, _meta, _form, env, state),
    do: {hazard(state, :generated_definition, args, env), env}

  defp head({form, _meta, [head | guards]}) when form in [:when, "when"], do: {head, guards}
  defp head(head), do: {head, []}
  defp default?({form, _meta, _args}), do: word(form) == "\\\\"
  defp default?(_ast), do: false

  defp alias_directive([target | options], meta, env, state) do
    case alias_token(target, :alias_target, env, state.source) do
      {:ok, token} ->
        token = Map.put(token, :declaration_start, meta_offset(state, meta))
        explicit = options |> List.first() |> keyword("as")
        name = alias_name(explicit)

        if explicit != nil and (name == nil or String.contains?(name, ".")) do
          {hazard(state, :unsupported_alias_binding, [target | options], env), env}
        else
          declare_alias(token, explicit, name, env, state)
        end

      {:error, _} ->
        {hazard(state, :grouped_or_dynamic_alias, target, env), env}
    end
  end

  defp alias_directive(args, _meta, env, state),
    do: {hazard(state, :grouped_or_dynamic_alias, args, env), env}

  defp declare_alias(token, explicit, name, env, state) do
    binding = name || List.last(String.split(token.name, "."))
    descriptor = %{target: token, explicit: not is_nil(explicit), binding: binding}
    token = Map.put(token, :alias_declaration, descriptor)
    state = add(state, token)
    state = put_alias_name(state, explicit, descriptor, env)
    {state, %{env | aliases: Map.put(env.aliases, binding, descriptor)}}
  end

  defp put_alias_name(state, nil, _descriptor, _env), do: state

  defp put_alias_name(state, explicit, descriptor, env) do
    case alias_token(explicit, :alias_name, env, state.source) do
      {:ok, name_token} -> add(state, Map.put(name_token, :declared_alias, descriptor))
      {:error, _} -> hazard(state, :unsupported_alias_binding, explicit, env)
    end
  end

  defp require_directive([target | options], meta, env, state) do
    case alias_token(target, :require_target, env, state.source) do
      {:ok, token} ->
        token = Map.put(token, :declaration_start, meta_offset(state, meta))
        {state, _env} = children(options, env, add(state, token))
        {state, env}

      {:error, _} ->
        {hazard(state, :grouped_or_dynamic_alias, target, env), env}
    end
  end

  defp require_directive(args, _meta, env, state),
    do: {hazard(state, :grouped_or_dynamic_alias, args, env), env}

  defp import_directive([target | options], meta, env, state) do
    case alias_token(target, :import_target, env, state.source) do
      {:ok, token} ->
        token = Map.put(token, :declaration_start, meta_offset(state, meta))
        state = add(state, token)
        options = List.first(options)
        only = keyword(options, "only")
        except = keyword(options, "except")
        {qualifiers, state} = qualifiers(only || except, token, meta, env, state)

        descriptor = %{
          target: token,
          only: not is_nil(only),
          except: not is_nil(except),
          qualifiers: qualifiers,
          module: env.module,
          function: env.function,
          scope: env.scope
        }

        {%{state | imports: [descriptor | state.imports]}, env}

      {:error, _} ->
        {hazard(state, :dynamic_import, target, env), env}
    end
  end

  defp import_directive(args, _meta, env, state),
    do: {hazard(state, :dynamic_import, args, env), env}

  defp qualifiers({:__literal__, _literal_meta, [list]}, target, meta, env, state)
       when is_list(list),
       do: qualifiers(list, target, meta, env, state)

  defp qualifiers(nil, _target, _meta, _env, state), do: {[], state}

  defp qualifiers(list, target, meta, env, state) when is_list(list) do
    Enum.reduce(list, {[], state}, fn
      {name, {:__literal__, arity_meta, [arity]}}, {entries, state} when is_integer(arity) ->
        name = word(name)
        start = {meta[:line], meta[:column]}
        finish = {arity_meta[:line], arity_meta[:column]}

        location =
          state.source.raw
          |> Enum.filter(fn {position, value} ->
            value == name and position >= start and position < finish
          end)
          |> List.last()

        case location do
          {{line, column}, _name} ->
            token =
              identifier(state.source, name, [line: line, column: column], :import_qualifier, env)

            token = Map.merge(token, %{arity: arity, import_target: key(target)})
            {[token | entries], add(state, token)}

          nil ->
            {entries, hazard(state, :unsupported_import_qualifier, list, env)}
        end

      _entry, {entries, state} ->
        {entries, hazard(state, :unsupported_import_qualifier, list, env)}
    end)
  end

  defp qualifiers(other, _target, _meta, env, state),
    do: {[], hazard(state, :unsupported_import_qualifier, other, env)}

  defp pipe([left, right], env, state) do
    {state, _} = walk(left, env, state)
    call(right, env, state, 1)
  end

  defp pipe(args, env, state), do: children(args, env, state)

  defp capture([{form, _meta, [call, {:__literal__, _arity_meta, [arity]}]}], env, state)
       when form in [:/, "/"] and is_integer(arity) do
    captured(call, arity, env, state)
  end

  defp capture(args, env, state), do: children(args, env, state)

  defp captured({name, meta, context}, arity, env, state)
       when (is_atom(name) or is_binary(name)) and not is_list(context) do
    {put_identifier(state, word(name), meta, :call, env, %{arity: arity, call_form: :capture}),
     env}
  end

  defp captured({{:., _dot_meta, [receiver, name]}, meta, _args}, arity, env, state) do
    state = remote_token(state, receiver, name, meta, arity, :capture, env)
    {state, _} = walk(receiver, env, state)
    {state, env}
  end

  defp captured(ast, _arity, env, state), do: walk(ast, env, state)

  defp call({{:., dot_meta, [receiver, name]}, meta, args}, env, state, extra)
       when (is_atom(name) or is_binary(name)) and is_list(args) do
    text = word(name)
    arity = length(args) + extra
    state = remote_token(state, receiver, text, meta, arity, :remote, env)

    reason =
      remote_dispatch_reason(receiver, text, args) ||
        remote_runtime_reason(receiver, text, arity, env, state.source)

    state = if reason, do: hazard(state, reason, {name, dot_meta, args}, env), else: state

    {state, _} = walk(receiver, env, state)
    children(args, env, state)
  end

  defp call({{:., _meta, [_receiver]} = form, _call_meta, args}, env, state, _extra) do
    children([form | args || []], env, state)
  end

  defp call({name, meta, args}, env, state, extra)
       when (is_atom(name) or is_binary(name)) and is_list(meta) do
    text = word(name)

    state =
      if identifier_name?(text) or (is_list(args) and text in @runtime_operators) do
        kind = if is_list(args), do: :call, else: :identifier
        arity = if is_list(args), do: length(args) + extra, else: extra

        put_identifier(state, text, meta, kind, env, %{arity: arity, call_form: :local})
        |> opaque_body(text, meta, env, :local)
        |> imported_runtime_hazard(text, meta, args, arity, env)
      else
        state
      end

    children(args, env, state)
  end

  defp call(ast, env, state, _extra) when is_list(ast), do: children(ast, env, state)
  defp call(_ast, env, state, _extra), do: {state, env}

  defp remote_dispatch_reason(_receiver, name, _args)
       when name in [
              "apply",
              "apply_after",
              "apply_interval",
              "make_fun",
              "function_exported?",
              "macro_exported?"
            ],
       do: :dynamic_dispatch

  defp remote_dispatch_reason(_receiver, name, [_, _, _ | _])
       when name in ["spawn", "spawn_link", "spawn_monitor", "spawn_opt"],
       do: :dynamic_dispatch

  defp remote_dispatch_reason(receiver, name, _args)
       when name in ["call", "block_call", "cast", "multicall", "async_call", "send_request"] do
    if word(receiver) in ["rpc", "erpc"], do: :dynamic_dispatch
  end

  defp remote_dispatch_reason(_receiver, _name, _args), do: nil

  defp remote_token(state, receiver, name, meta, arity, form, env) do
    state =
      put_identifier(state, word(name), meta, :call, env, %{
        arity: arity,
        call_form: form,
        receiver: receiver
      })

    state = opaque_body(state, word(name), meta, env, form)

    static =
      alias_name(receiver) ||
        match?({module, _, _} when module in [:__MODULE__, "__MODULE__"], receiver)

    if static, do: state, else: hazard(state, :dynamic_receiver, {name, meta, [receiver]}, env)
  end

  defp opaque_body(state, name, meta, env, form) do
    if env.function == nil and form != :capture and
         env.attribute not in ["spec", "type", "typep", "opaque", "callback", "macrocallback"],
       do: hazard(state, :opaque_module_body_call, {name, meta, []}, env),
       else: state
  end

  defp add_alias(ast, role, env, state) do
    case alias_token(ast, role, env, state.source) do
      {:ok, token} -> add(state, token)
      {:error, _} -> hazard(state, :unsupported_module_token, ast, env)
    end
  end

  # Resolve authored spellings only to widen unsafe-API recognition. This never
  # supplies semantic identity or permits publication.
  defp remote_runtime_reason(receiver, name, arity, env, source) do
    case Map.fetch(@runtime_apis, name) do
      {:ok, modules} ->
        receiver_runtime_reason(receiver, modules, arity, env, source)

      :error ->
        nil
    end
  end

  defp receiver_runtime_reason(receiver, modules, arity, env, source) do
    case alias_token(receiver, :reference, env, source) do
      {:ok, token} ->
        runtime_api_reason(Map.get(modules, authored_alias_name(token)), arity)

      {:error, _} ->
        Enum.find_value(modules, fn {_module, api} -> runtime_api_reason(api, arity) end)
    end
  end

  defp imported_runtime_hazard(state, name, meta, args, arity, env) do
    reason = imported_runtime_reason(state.imports, name, arity, env)

    if reason, do: hazard(state, reason, {name, meta, args}, env), else: state
  end

  defp imported_runtime_reason(imports, name, arity, env) do
    case Map.fetch(@runtime_apis, name) do
      {:ok, modules} ->
        Enum.find_value(imports, &import_runtime_reason(&1, modules, name, arity, env))

      :error ->
        nil
    end
  end

  defp import_runtime_reason(import, modules, name, arity, env) do
    member = Enum.any?(import.qualifiers, &(&1.name == name and &1.arity == arity))

    offered =
      cond do
        import.only -> member
        import.except -> not member
        true -> true
      end

    if offered and import.target.scope == Enum.take(env.scope, length(import.target.scope)),
      do: runtime_api_reason(Map.get(modules, authored_alias_name(import.target)), arity)
  end

  defp runtime_api_reason({reason, arities}, arity),
    do: if(arity in arities, do: reason)

  defp runtime_api_reason(nil, _arity), do: nil

  defp authored_alias_name(%{name: "Elixir." <> name}), do: name
  defp authored_alias_name(%{name: name, alias_binding: nil}), do: name

  defp authored_alias_name(%{name: name, alias_binding: binding}) do
    suffix = name |> String.split(".") |> Enum.drop(1)

    [authored_alias_name(binding.target) | suffix]
    |> Enum.join(".")
    |> String.trim_leading("Elixir.")
  end

  defp alias_token({form, meta, parts}, role, env, source)
       when form in [:__aliases__, "__aliases__"] and is_list(parts) do
    names = Enum.map(parts, &word/1)

    with true <- Enum.all?(names, &is_binary/1),
         name = Enum.join(names, "."),
         {:ok, token} <- safe_identifier(source, name, meta, :module, env) do
      binding = Map.get(env.aliases, hd(names))
      {:ok, Map.merge(token, %{role: role, alias_binding: binding, segments: names})}
    else
      _ -> {:error, :elixir_rename_dynamic_alias}
    end
  end

  defp alias_token(_ast, _role, _env, _source), do: {:error, :elixir_rename_dynamic_alias}

  defp alias_name({form, _meta, parts}) when form in [:__aliases__, "__aliases__"] do
    if Enum.all?(parts, &(is_atom(&1) or is_binary(&1))), do: Enum.map_join(parts, ".", &word/1)
  end

  defp alias_name(_ast), do: nil

  defp put_identifier(state, name, meta, kind, env, fields) do
    case safe_identifier(state.source, name, meta, kind, env) do
      {:ok, token} -> add(state, Map.merge(token, fields))
      {:error, _} -> hazard(state, :unauthored_identifier, {name, meta, []}, env)
    end
  end

  defp identifier(source, name, meta, kind, env) do
    {:ok, start, first} = position(source, meta[:line], meta[:column])
    ending = start + byte_size(name)

    unless ending <= byte_size(source.content) and
             binary_part(source.content, start, byte_size(name)) == name do
      raise ArgumentError,
            "identifier metadata does not identify exact authored bytes: #{inspect(name)}"
    end

    %{
      path: source.path,
      kind: kind,
      name: name,
      start: start,
      end: ending,
      range: %{"start" => first, "end" => Map.update!(first, "character", &(&1 + utf16(name)))},
      code_position: %{line: meta[:line], column: meta[:column]},
      module: env.module,
      function: env.function,
      attribute: env.attribute,
      scope: env.scope
    }
  end

  defp safe_identifier(source, name, meta, kind, env) do
    {:ok, identifier(source, name, meta, kind, env)}
  rescue
    _error in [ArgumentError, MatchError] -> {:error, :elixir_rename_unauthored_identifier}
  end

  defp add(state, token), do: %{state | tokens: [token | state.tokens]}

  defp hazard(state, reason, ast, env) do
    names = names(ast, []) |> Enum.uniq()

    start =
      case ast do
        {_form, meta, _args} when is_list(meta) ->
          case position(state.source, meta[:line], meta[:column]) do
            {:ok, offset, _position} -> offset
            {:error, _} -> nil
          end

        _ ->
          nil
      end

    entry = %{
      reason: reason,
      names: names,
      module: env.module,
      function: env.function,
      scope: env.scope,
      start: start
    }

    %{state | hazards: [entry | state.hazards]}
  end

  defp names({name, _meta, args}, acc) do
    acc = if word(name), do: [word(name) | acc], else: names(name, acc)
    names(args, acc)
  end

  defp names(list, acc) when is_list(list), do: Enum.reduce(list, acc, &names/2)
  defp names({left, right}, acc), do: names(right, names(left, acc))
  defp names(value, acc) when is_atom(value) or is_binary(value), do: [word(value) | acc]
  defp names(_value, acc), do: acc

  defp keyword(list, key) when is_list(list) do
    Enum.find_value(list, fn
      {name, value} -> if word(name) == key, do: value
      _ -> nil
    end)
  end

  defp keyword(_value, _key), do: nil

  defp meta_offset(state, meta) do
    {:ok, offset, _position} = position(state.source, meta[:line], meta[:column])
    offset
  end

  defp identifier_name?(name) when is_binary(name),
    do:
      Regex.match?(~r/\A[\p{Ll}_][\p{L}\p{M}\p{N}_]*[!?]?\z/u, name) and
        not String.starts_with?(name, "__")

  defp lines(source), do: source |> lines(0, []) |> List.to_tuple()

  defp lines(source, offset, acc) do
    case :binary.match(source, ["\r", "\n"]) do
      {size, 1} ->
        newline =
          if :binary.at(source, size) == 13 and byte_size(source) > size + 1 and
               :binary.at(source, size + 1) == 10, do: 2, else: 1

        consumed = size + newline

        lines(binary_part(source, consumed, byte_size(source) - consumed), offset + consumed, [
          {offset, binary_part(source, 0, size)} | acc
        ])

      :nomatch ->
        Enum.reverse([{offset, source} | acc])
    end
  end

  defp fetch_line(source, index) when index >= 0 and index < tuple_size(source.lines),
    do: elem(source.lines, index)

  defp fetch_line(_source, _index), do: nil

  defp codepoint_prefix(_text, 0, bytes, units), do: {:ok, bytes, units}

  defp codepoint_prefix(<<point::utf8, rest::binary>> = text, count, bytes, units) do
    codepoint_prefix(
      rest,
      count - 1,
      bytes + byte_size(text) - byte_size(rest),
      units + if(point > 0xFFFF, do: 2, else: 1)
    )
  end

  defp codepoint_prefix(_text, _count, _bytes, _units), do: {:error, :out_of_bounds}

  defp utf16(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)

  defp utf16_offset(_text, 0, bytes), do: {:ok, bytes}

  defp utf16_offset(<<point::utf8, rest::binary>> = text, units, bytes) do
    width = if point > 0xFFFF, do: 2, else: 1

    if width <= units,
      do: utf16_offset(rest, units - width, bytes + byte_size(text) - byte_size(rest)),
      else: {:error, :surrogate_split}
  end

  defp utf16_offset(_text, _units, _bytes), do: {:error, :out_of_bounds}
end
