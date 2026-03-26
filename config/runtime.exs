import Config

if config_env() == :prod do
  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :ogol, Ogol.HMIWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base:
      System.get_env("SECRET_KEY_BASE") ||
        raise("environment variable SECRET_KEY_BASE is missing"),
    server: true
end
