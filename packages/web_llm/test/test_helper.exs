{:ok, _supervisor} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: WebLLMTest.PubSub}, WebLLMTest.Endpoint],
    strategy: :one_for_one
  )

ExUnit.start()
