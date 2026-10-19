defmodule ReqLLM.Providers.Minimax.ResponseBuilder do
  @moduledoc """
  MiniMax-specific ResponseBuilder implementation.

  Assembles progressive streamed reasoning detail fragments into the same
  normalized shape produced by non-streaming responses.
  """

  @behaviour ReqLLM.Provider.ResponseBuilder

  alias ReqLLM.Message
  alias ReqLLM.Provider.Defaults.ResponseBuilder, as: DefaultBuilder

  @impl true
  def build_response(chunks, metadata, opts) do
    with {:ok, response} <- DefaultBuilder.build_response(chunks, metadata, opts) do
      {:ok, assemble_response_reasoning_details(response)}
    end
  end

  defp assemble_response_reasoning_details(%{message: %{reasoning_details: details}} = response)
       when is_list(details) do
    assembled_details = assemble_reasoning_details(details)
    message = %{response.message | reasoning_details: assembled_details}
    context = update_context_message(response.context, response.message, assembled_details)
    %{response | message: message, context: context}
  end

  defp assemble_response_reasoning_details(response), do: response

  defp update_context_message(%ReqLLM.Context{messages: messages} = context, message, details) do
    case messages do
      [] ->
        context

      _ ->
        {init, [last]} = Enum.split(messages, -1)

        if is_struct(last, Message) and last.role == message.role do
          %{context | messages: init ++ [%{last | reasoning_details: details}]}
        else
          context
        end
    end
  end

  defp update_context_message(context, _message, _details), do: context

  defp assemble_reasoning_details(details) do
    details
    |> Enum.reduce(%{keys: [], details: %{}}, &accumulate_reasoning_detail/2)
    |> then(fn acc -> Enum.map(acc.keys, &Map.fetch!(acc.details, &1)) end)
  end

  defp accumulate_reasoning_detail(%Message.ReasoningDetails{provider: :minimax} = detail, acc) do
    key = reasoning_detail_key(detail)

    if Map.has_key?(acc.details, key) do
      details = Map.update!(acc.details, key, &merge_reasoning_details(&1, detail))
      %{acc | details: details}
    else
      %{acc | keys: acc.keys ++ [key], details: Map.put(acc.details, key, detail)}
    end
  end

  defp accumulate_reasoning_detail(detail, acc) do
    key = {:passthrough, length(acc.keys)}
    %{acc | keys: acc.keys ++ [key], details: Map.put(acc.details, key, detail)}
  end

  defp merge_reasoning_details(left, right) do
    %{
      left
      | text: join_text(left.text, right.text),
        signature: left.signature || right.signature,
        encrypted?: left.encrypted? || right.encrypted?,
        provider_data: Map.merge(left.provider_data || %{}, right.provider_data || %{})
    }
  end

  defp reasoning_detail_key(%Message.ReasoningDetails{signature: signature})
       when is_binary(signature) and signature != "" do
    {:signature, signature}
  end

  defp reasoning_detail_key(%Message.ReasoningDetails{} = detail) do
    {:index, detail.index, detail.format}
  end

  defp join_text(left, right) when is_binary(left) and is_binary(right), do: left <> right
  defp join_text(nil, right), do: right
  defp join_text(left, nil), do: left
  defp join_text(left, right), do: "#{left}#{right}"
end
