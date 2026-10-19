# Modified by Oh-My-Jido contributors, 2026-10-13: bind request-scoped error
# normalization to the selected model before native error telemetry. Original
# ReqLLM 1.28.0 source remains under Apache License 2.0; see LICENSE and UPSTREAM.json.
defmodule ReqLLM.Step.Telemetry do
  @moduledoc """
  Req step that emits request and reasoning telemetry for Req-backed flows.
  """

  alias ReqLLM.Telemetry

  @doc """
  Attaches request lifecycle telemetry to a Req request.
  """
  @spec attach(Req.Request.t(), LLMDB.Model.t(), keyword(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = req, %LLMDB.Model{} = model, opts \\ [], extra \\ []) do
    extra =
      Keyword.put_new(
        extra,
        :operation,
        req.options[:operation] || Keyword.get(opts, :operation, :chat)
      )

    original_opts = Keyword.get(opts, :telemetry_original_opts, opts)

    context =
      Telemetry.new_context(
        model,
        original_opts,
        Keyword.put(
          extra,
          :reasoning_contract,
          Telemetry.reasoning_contract_for(model, original_opts, req)
        )
      )

    req
    |> Telemetry.put_request_context(context)
    |> put_error_context(model, opts)
    |> Req.Request.append_request_steps(llm_telemetry_start: &__MODULE__.handle_request/1)
    |> Req.Request.append_response_steps(llm_telemetry_stop: &__MODULE__.handle_response/1)
    |> Req.Request.append_error_steps(llm_telemetry_exception: &__MODULE__.handle_error/1)
  end

  defp put_error_context(req, model, opts) do
    case Keyword.get(opts, :stream_error_normalizer) do
      callback when is_function(callback, 2) ->
        req
        |> Req.Request.put_private(:req_llm_error_context, {callback, model})
        |> Req.Request.delete_option(:stream_error_normalizer)

      _ ->
        req
    end
  end

  @doc false
  @spec handle_request(Req.Request.t()) :: Req.Request.t()
  def handle_request(%Req.Request{} = req) do
    case Telemetry.request_context(req) do
      nil ->
        req

      context ->
        context = Telemetry.start_request(context, req)
        Telemetry.put_request_context(req, context)
    end
  end

  @doc false
  @spec handle_response({Req.Request.t(), Req.Response.t()}) ::
          {Req.Request.t(), Req.Response.t()}
  def handle_response({%Req.Request{} = req, %Req.Response{} = resp}) do
    case Telemetry.request_context(req) do
      nil ->
        {req, resp}

      context ->
        context = Telemetry.stop_request(context, resp)
        req = Telemetry.put_request_context(req, context)
        resp = Telemetry.put_response_context(resp, context)
        {req, resp}
    end
  end

  @doc false
  @spec handle_error({Req.Request.t(), Exception.t() | term()}) ::
          {Req.Request.t(), Exception.t() | term()}
  def handle_error({%Req.Request{} = req, error}) do
    case Telemetry.request_context(req) do
      nil ->
        {req, error}

      context ->
        context =
          if context.request_started? do
            context
          else
            Telemetry.start_request(context, req)
          end

        context = Telemetry.exception_request(context, error)
        req = Telemetry.put_request_context(req, context)
        {req, error}
    end
  end
end
