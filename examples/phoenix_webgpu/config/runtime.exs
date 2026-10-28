import Config

secret_key_base =
  if config_env() == :prod do
    System.fetch_env!("SECRET_KEY_BASE")
  else
    :crypto.strong_rand_bytes(64) |> Base.encode64()
  end

config :phoenix_webgpu, PhoenixWebGPUWeb.Endpoint, secret_key_base: secret_key_base

if module_url = System.get_env("WEB_LLM_MODULE_URL") do
  config :phoenix_webgpu, :web_llm_module_url, module_url
end

if config_env() == :prod do
  host = System.get_env("PHX_HOST", "localhost")
  port = String.to_integer(System.get_env("PORT", "4000"))

  config :phoenix_webgpu, PhoenixWebGPUWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: port],
    url: [host: host, scheme: "https", port: 443],
    check_origin: ["https://#{host}"]
end
