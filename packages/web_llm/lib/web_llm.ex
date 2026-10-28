defmodule WebLLM do
  @moduledoc """
  WebLLM models for ReqLLM.

  [WebLLM](https://webllm.mlc.ai) runs language models on the user's GPU
  through WebGPU, inside a web page. This library makes such a model an
  ordinary ReqLLM model (provider `:web_llm`), reached in one of two ways:

    * from a BEAM running **in the page** (Popcorn), through the browser's
      `fetch` (`WebLLM.Popcorn.FetchStream`);
    * from a BEAM on a **server**, through the user's Phoenix LiveView socket
      (`WebLLM.Live.Transport` and `WebLLM.Live.Component`).

  Either way the page runs the JavaScript bridge in `priv/static/web_llm.js`,
  which answers OpenAI-style chat-completion requests for the reserved origin
  `https://web-llm.invalid`. No request leaves the browser and no credential
  is involved.

      model = WebLLM.model("Qwen3-8B-q4f16_1-MLC", client: client_id)
      {:ok, response} = ReqLLM.stream_text(model, "Hello!")
  """

  @origin "https://web-llm.invalid"
  @client_header "x-web-llm-client"
  @default_context 16_384
  @default_output 4_096

  @typedoc "A LiveView client id: 1 to 128 characters from `A-Z a-z 0-9 _ -`."
  @type client :: String.t()

  @typedoc "Options for `model/2`."
  @type model_option ::
          {:client, client()}
          | {:context_window, pos_integer()}
          | {:max_output, pos_integer()}
          | {:reasoning, boolean()}

  @doc """
  Returns a ReqLLM model spec for a WebLLM model id, such as
  `"Qwen3-8B-q4f16_1-MLC"`.

  Options:

    * `:client` - the LiveView client that runs the model (server use). It
      can also be chosen per request with the `#{@client_header}` header, see
      `client_header/0`.
    * `:context_window` - tokens the page engine is configured for
      (default #{@default_context}).
    * `:max_output` - output token limit (default #{@default_output}).
    * `:reasoning` - whether the model emits reasoning (default `false`).
  """
  @spec model(String.t(), [model_option()]) :: map()
  def model(model_id, opts \\ []) when is_binary(model_id) and is_list(opts) do
    %{
      provider: :web_llm,
      id: model_id,
      base_url: base_url(Keyword.get(opts, :client)),
      capabilities: %{
        chat: true,
        tools: %{enabled: true, streaming: true, parallel: false},
        streaming: %{text: true, tool_calls: true},
        reasoning: %{enabled: Keyword.get(opts, :reasoning, false)}
      },
      limits: %{
        context: Keyword.get(opts, :context_window, @default_context),
        output: Keyword.get(opts, :max_output, @default_output)
      },
      modalities: %{input: [:text], output: [:text]}
    }
  end

  @doc "Base URL of the page bridge, optionally scoped to one LiveView client."
  @spec base_url(client() | nil) :: String.t()
  def base_url(nil), do: @origin <> "/v1"
  def base_url(client), do: "#{@origin}/clients/#{validate_client!(client)}/v1"

  @doc "The reserved origin the page bridge answers."
  @spec origin() :: String.t()
  def origin, do: @origin

  @doc """
  Request header that routes one request to a LiveView client, overriding the
  client in the base URL. Pass it with ReqLLM's `:req_http_options`:

      req_http_options: [headers: [{WebLLM.client_header(), client_id}]]
  """
  @spec client_header() :: String.t()
  def client_header, do: @client_header

  @doc "Whether `value` is a valid client id."
  @spec client?(term()) :: boolean()
  def client?(value) when is_binary(value), do: value =~ ~r/\A[A-Za-z0-9_-]{1,128}\z/
  def client?(_value), do: false

  @doc "Returns a new random client id."
  @spec new_client() :: client()
  def new_client, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp validate_client!(client) do
    if client?(client),
      do: client,
      else: raise(ArgumentError, "invalid WebLLM client id: #{inspect(client)}")
  end
end
