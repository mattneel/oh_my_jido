defmodule OhMyJidoBrowser.Models do
  @moduledoc """
  The models the browser agent can run on.

  * `:openrouter` is `openai/gpt-6-luna` on OpenRouter with low reasoning,
    using the saved API key.
  * `{:local, id}` is a keyless WebLLM model running on this machine's GPU.
    `WebLLM.model/1` from `packages/web_llm` selects its `:web_llm` provider;
    the shared browser bridge answers `https://web-llm.invalid/v1` inside
    the page, so prompts never leave the browser.
  * `:scripted` replays the end-to-end test build's scripted turns.
  """

  @openrouter "openrouter:openai/gpt-6-luna"

  @type choice :: :openrouter | {:local, String.t()} | :scripted

  @doc "Model input for `OhMyJido.start_session/2`."
  @spec spec(choice()) :: term()
  def spec(:openrouter), do: @openrouter
  def spec(:scripted), do: @openrouter

  def spec({:local, id}), do: WebLLM.model(id)

  @doc "Account the credential resolver answers for this choice; nil when none is needed."
  @spec account(choice()) :: String.t() | nil
  def account(:openrouter), do: "openrouter"
  def account({:local, _id}), do: nil
  def account(:scripted), do: nil

  @doc "Short label for the status line."
  @spec label(choice()) :: String.t()
  def label(:openrouter), do: "openai/gpt-6-luna on OpenRouter, low reasoning"
  def label({:local, id}), do: "#{id} on this GPU (WebLLM)"
  def label(:scripted), do: "scripted model (test build)"

  @doc "Value used by the page's model picker."
  @spec encode(choice()) :: String.t()
  def encode(:openrouter), do: "openrouter"
  def encode(:scripted), do: "scripted"
  def encode({:local, id}), do: "local:" <> id

  @doc "Parses a model picker value."
  @spec decode(String.t()) :: {:ok, choice()} | :error
  def decode("openrouter"), do: {:ok, :openrouter}
  def decode("scripted"), do: {:ok, :scripted}
  def decode("local:" <> id) when byte_size(id) in 1..200, do: {:ok, {:local, id}}
  def decode(_value), do: :error
end
