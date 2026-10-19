defmodule ElixosHost.Privileges do
  @moduledoc "A fixed helper allow-list, never a command, argv or UID grant."

  def invoke(context, %{name: name} = request, options) do
    cond do
      map_size(request) != 1 or not Elixos.Privileges.valid_name?(name) ->
        {:error, :invalid_helper_request}

      name not in Keyword.get(options, :helpers, []) ->
        {:error, :helper_not_allowed}

      true ->
        with :ok <-
               OhMyJido.Tool.authorize(context, :privileges, %{operation: :helper, name: name}) do
          # Only Elixos' inherited, allow-listed helper client is used.
          Elixos.Privileges.request(name)
        end
    end
  catch
    :exit, _reason -> {:error, :privileges_service_unavailable}
  end

  def invoke(_context, _request, _options), do: {:error, :invalid_helper_request}
end
