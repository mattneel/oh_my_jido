defmodule OhMyJido.Eval.PeerIO do
  @moduledoc false
  use GenServer

  alias OhMyJido.Eval.Output

  def start_link(root, request, stream \\ :stdout) do
    GenServer.start_link(__MODULE__, {root, request, stream})
  end

  @impl true
  def init({root, request, stream}),
    do: {:ok, %{root: root, request: request, stream: stream, written: 0}}

  @impl true
  def handle_info({:io_request, from, ref, request}, %{request: :stdio} = state) do
    reply = :io.request(state.root, {:omj_stdio, state.stream, request})
    send(from, {:io_reply, ref, reply})
    {:noreply, state}
  end

  def handle_info({:io_request, from, ref, request}, state) do
    {reply, state} = dispatch(request, state)
    send(from, {:io_reply, ref, reply})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  defp dispatch({:requests, requests}, state) do
    Enum.reduce_while(requests, {:ok, state}, fn request, {_reply, acc} ->
      case dispatch(request, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        other -> {:halt, other}
      end
    end)
  end

  defp dispatch({:put_chars, encoding, chars}, state), do: chars(chars, encoding, state)
  defp dispatch({:put_chars, chars}, state), do: chars(chars, :unicode, state)

  defp dispatch({:put_chars, encoding, module, function, args}, state) do
    chars(apply(module, function, args), encoding, state)
  rescue
    _ -> {{:error, :request}, state}
  end

  defp dispatch({:omj_api, operation}, state) do
    request = state.request
    reply = :io.request(state.root, {:omj_eval, request.generation, request.id, operation})
    {reply, state}
  end

  defp dispatch({:getopts}, state), do: {[binary: true, encoding: :unicode], state}
  defp dispatch(:getopts, state), do: {[binary: true, encoding: :unicode], state}
  defp dispatch({:setopts, _opts}, state), do: {:ok, state}
  defp dispatch(_request, state), do: {{:error, :enotsup}, state}

  defp chars(chars, encoding, state) do
    text = :unicode.characters_to_binary(chars, encoding)
    limit = state.request.output_limit
    {piece, clipped?} = Output.clip(text, max(limit - state.written, 0))
    operation = {:output, state.stream, piece, clipped?}
    request = state.request
    reply = :io.request(state.root, {:omj_eval, request.generation, request.id, operation})
    {reply, %{state | written: state.written + byte_size(piece)}}
  rescue
    _ -> {{:error, :request}, state}
  end
end
