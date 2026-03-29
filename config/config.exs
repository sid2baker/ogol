import Config

config :ogol, Ogol.HMIWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: Ogol.HMIWeb.ErrorHTML, json: Ogol.HMIWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ogol.HMI.PubSub,
  live_view: [signing_salt: "ogol_hmi_live_view"],
  secret_key_base: "7AxUaMlIfj0Z4tOL0yBh5s8SPu64zxaLxFjUqqh6cv6CY1P9TVJjbQc0q93LxeGd"

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :esbuild,
  version: "0.25.4",
  ogol_hmi: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "4.1.13",
  ogol_hmi: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("..", __DIR__),
    env: %{
      "PATH" => Path.expand("../bin", __DIR__) <> ":" <> System.get_env("PATH", "")
    }
  ]

import_config "#{config_env()}.exs"
