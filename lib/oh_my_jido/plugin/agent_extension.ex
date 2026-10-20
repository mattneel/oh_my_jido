defmodule OhMyJido.Plugin.AgentExtension do
  @moduledoc """
  Static native AI profile authoring for `OhMyJido.Plugin`.

  Add this extension to the caller's `use Jido.AI.Agent` declaration:

      use Jido.AI.Agent,
        name: "my_agent",
        extensions: [OhMyJido.Plugin.AgentExtension]

  Declare `OhMyJido.Plugin` in `agent do` with the selected bundles and host
  context provider. The native AI DSL lowers first; this extension adds the
  selected bound Actions to those profiles. Domain tools, models, controls,
  interceptors, transport, and the native coordinator are not replaced. Plain
  coding input routes are still declared explicitly in `routes do`.

  Programmatic profile authors can instead combine `Plugin.tool_catalog/1`
  entries with their own native catalog before constructing the profile.
  """

  use Spark.Dsl.Extension
  @behaviour Jido.Agent.Extension

  alias Jido.AI.{Configuration, Orchestration}
  alias OhMyJido.Plugin

  @impl true
  def lower_agent(config, entities) do
    with {Plugin, opts} <- Enum.find(config.plugins, &(elem(&1, 0) == Plugin)),
         {:ok, plugin_config} <- Plugin.normalize(Map.new(opts)),
         {Configuration.Plugin, ai_opts} <-
           Enum.find(config.plugins, &(elem(&1, 0) == Configuration.Plugin)),
         {:ok, profiles} <- bind_profiles(Keyword.fetch!(ai_opts, :profiles), plugin_config) do
      plugins =
        Enum.map(config.plugins, fn
          {module, options} when module in [Configuration.Plugin, Orchestration.Plugin] ->
            {module, Keyword.put(options, :profiles, profiles)}

          declaration ->
            declaration
        end)

      {:ok, %{config | plugins: plugins}, entities}
    else
      nil -> authoring_error(:plugin_and_native_ai_profiles_required)
      {:error, reason} -> authoring_error(reason)
    end
  end

  defp bind_profiles(profiles, config) do
    profiles
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {id, profile}, {:ok, bound} ->
      case Plugin.bind_profile(profile, config) do
        {:ok, profile} -> {:cont, {:ok, Map.put(bound, id, profile)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp authoring_error(reason),
    do:
      Jido.Agent.Authoring.error("Invalid OhMyJido.Plugin AI attachment", %{
        reason: reason
      })
end
