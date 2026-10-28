defmodule WebLLM.Provider do
  @moduledoc """
  ReqLLM provider `:web_llm`: OpenAI chat completions answered by WebLLM in a
  web page.

  Requests use ReqLLM's OpenAI chat encoding and response decoding. They never
  carry credentials: the model runs on the user's GPU, so there is no key to
  send and no account to bill. `credentials_required?/0` declares this to
  hosts that resolve credentials per request.

  The request does not go over the network. Streaming requests carry
  `WebLLM.Transport.module/0` under the Finch request's private
  `:req_llm_stream_transport` key, which ReqLLM's Finch client uses instead of
  `Finch.stream/5`; non-streaming requests run through the same transport as
  their Req adapter. `WebLLM.Application` registers the provider; it can also
  be listed in `config :req_llm, :custom_providers`.
  """

  use ReqLLM.Provider,
    id: :web_llm,
    default_base_url: "https://web-llm.invalid/v1"

  use ReqLLM.Provider.Defaults

  alias ReqLLM.Provider.Options

  @provider_schema []

  @doc "WebLLM requests never need a credential."
  @spec credentials_required?() :: false
  def credentials_required?, do: false

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    {:ok, %LLMDB.Model{} = model} = ReqLLM.model(model_input)

    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    extra_keys = ReqLLM.Provider.Defaults.extra_option_keys(__MODULE__)

    %{request | adapter: WebLLM.Transport}
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.register_options(extra_keys)
    |> Req.Request.merge_options([model: model.provider_model_id || model.id] ++ user_opts)
    |> ReqLLM.Step.Retry.attach(user_opts)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.prepend_request_steps(llm_encode_body: &encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Telemetry.attach(model, user_opts)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    operation = opts[:operation] || :chat

    stream_opts =
      opts
      |> Options.strip_stream_request_options()
      |> Keyword.merge(stream: true, context: context, operation: operation)

    with {:ok, processed_opts} <- Options.process(__MODULE__, operation, model, stream_opts) do
      base_url = Options.effective_base_url(__MODULE__, model, processed_opts)

      headers =
        [{"content-type", "application/json"}, {"accept", "text/event-stream"}] ++
          ReqLLM.Provider.Utils.extract_custom_headers(processed_opts[:req_http_options])

      request =
        :post
        |> Finch.build(endpoint(base_url), headers, stream_body(model, context, processed_opts))
        |> Finch.Request.put_private(:req_llm_stream_transport, WebLLM.Transport.module())

      {:ok, request}
    end
  end

  defp endpoint(base_url), do: String.trim_trailing(base_url, "/") <> "/chat/completions"

  defp stream_body(model, context, opts) do
    options =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.merge(model: model.provider_model_id || model.id, context: context, stream: true)

    Req.new(method: :post, url: "https://web-llm.invalid")
    |> Req.Request.register_options(
      ReqLLM.Provider.Defaults.extra_option_keys(__MODULE__) ++ [:context, :operation]
    )
    |> Req.Request.merge_options(options)
    |> encode_body()
    |> Req.Steps.encode_body()
    |> Map.fetch!(:body)
  end
end
