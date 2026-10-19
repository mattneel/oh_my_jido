defmodule OhMyJido.Intelligence.ElixirRename.Namespace do
  @moduledoc false

  # Audited ElixirLS 0.31.1 profile: Completion.completion/4 sets isIncomplete
  # whenever its result is nonempty to request client-side reordering, NOT after
  # truncating it. CompletionEngine.get_modules/3 enumerates loaded modules,
  # loaded application module lists and current-document declarations. Query an
  # actual namespace prefix: the separate required-alias suggestions deliberately
  # omit tasks and protocol implementations and cannot prove their absence.
  @max_items 20_000
  @module_details ~w(module behaviour protocol exception struct implementation task)

  def supported?(%{"name" => "ElixirLS", "version" => "0.31.1"}), do: true
  def supported?(_info), do: false

  def availability_params(destination) do
    %{"command" => "llmTypeInfo:oh_my_jido_rename", "arguments" => [canonical(destination)]}
  end

  # Exact native module availability is independent of completion plugins. A
  # negative is only the provider's loadable/compiled boundary, not proof about
  # arbitrary beam files or failed on_load modules; the bounded default catalog
  # and complete authored declaration inventory corroborate that boundary.
  def availability(
        %{
          "module" => module,
          "types" => types,
          "specs" => specs,
          "callbacks" => callbacks,
          "dialyzer_contracts" => contracts
        },
        destination
      )
      when is_binary(module) and is_list(types) and is_list(specs) and is_list(callbacks) and
             is_list(contracts) do
    if canonical(module) == canonical(destination),
      do: {:error, :elixir_rename_destination_module_exists},
      else: {:error, :elixir_rename_native_namespace_evidence_incomplete}
  end

  def availability(%{"error" => "Module not found or not compiled"}, destination) do
    {:ok,
     %{
       command: "llmTypeInfo",
       module: canonical(destination),
       native_scope: :loadable_or_compiled_modules,
       result: :not_found_or_not_compiled
     }}
  end

  def availability(_result, _destination),
    do: {:error, :elixir_rename_native_namespace_evidence_incomplete}

  def anchor(target, matches) do
    canonical = canonical(target.module_name)
    parent = canonical |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

    case Enum.find([target | matches], fn token ->
           token.kind in [:module, :module_definition] and
             Map.get(token, :alias_binding) == nil and canonical(token.name) == canonical
         end) do
      nil ->
        {:error, :elixir_rename_namespace_query_context_unavailable}

      token ->
        absolute_prefix = if String.starts_with?(token.name, "Elixir."), do: "Elixir.", else: ""
        prefix = absolute_prefix <> if(parent == "", do: "", else: parent <> ".")
        width = div(byte_size(:unicode.characters_to_binary(prefix, :utf8, {:utf16, :little})), 2)
        first = Map.update!(token.range["start"], "character", &(&1 + width))
        {:ok, %{token | range: %{"start" => first, "end" => first}}}
    end
  end

  def check(%{"items" => items, "isIncomplete" => incomplete}, old, destination)
      when is_list(items) and is_boolean(incomplete) and length(items) <= @max_items do
    with {:ok, modules} <- modules(items),
         true <- MapSet.member?(modules, canonical(old)),
         false <- MapSet.member?(modules, canonical(destination)) do
      {:ok,
       %{
         profile: :elixirls_0_31_1_default_namespace_catalog,
         native_scope: :loaded_modules_loaded_application_modules_current_document,
         namespace_prefix_query: true,
         raw_is_incomplete: incomplete,
         raw_incomplete_reason: :provider_requests_reordering_not_truncation,
         item_count: length(items),
         module_count: MapSet.size(modules),
         existing_module_sentinel: canonical(old),
         destination_absent: canonical(destination)
       }}
    else
      false -> {:error, :elixir_rename_native_namespace_evidence_incomplete}
      true -> {:error, :elixir_rename_destination_module_exists}
      {:error, _} = error -> error
    end
  end

  def check(%{"items" => items}, _old, _destination)
      when is_list(items) and length(items) > @max_items,
      do: {:error, :elixir_rename_native_namespace_limit}

  def check(_result, _old, _destination),
    do: {:error, :elixir_rename_native_namespace_evidence_incomplete}

  defp modules(items) do
    Enum.reduce_while(items, {:ok, MapSet.new()}, &module_item/2)
  end

  defp module_item(%{"kind" => kind, "detail" => detail} = item, {:ok, modules})
       when kind in [8, 9, 22] and detail in @module_details do
    case item do
      %{"label" => label, "labelDetails" => %{"description" => ":" <> _atom}}
      when is_binary(label) ->
        # Native Erlang atoms are outside the Elixir.<Alias> destination
        # namespace; they cannot collide with a supported authored alias.
        {:cont, {:ok, modules}}

      %{"label" => label, "labelDetails" => %{"description" => description}}
      when is_binary(label) and is_binary(description) ->
        name = description |> String.trim_leading("alias ") |> canonical()

        if Regex.match?(~r/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/, name),
          do: {:cont, {:ok, MapSet.put(modules, name)}},
          else: {:halt, {:error, :elixir_rename_native_namespace_evidence_incomplete}}

      _ ->
        {:halt, {:error, :elixir_rename_native_namespace_evidence_incomplete}}
    end
  end

  defp module_item(
         %{
           "kind" => 9,
           "detail" => "alias",
           "label" => label,
           "labelDetails" => %{"description" => description}
         },
         {:ok, modules}
       )
       when is_binary(label) and is_binary(description) do
    # Required-alias and virtual namespace suggestions are not canonical
    # module entries. Exact availability and real module items own occupancy.
    {:cont, {:ok, modules}}
  end

  defp module_item(%{"kind" => 9}, _acc),
    do: {:halt, {:error, :elixir_rename_native_namespace_evidence_incomplete}}

  defp module_item(item, {:ok, modules}) when is_map(item), do: {:cont, {:ok, modules}}

  defp module_item(_item, _acc),
    do: {:halt, {:error, :elixir_rename_native_namespace_evidence_incomplete}}

  defp canonical(name), do: String.trim_leading(name, "Elixir.")
end
