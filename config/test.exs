import Config

config :ogol, Ogol.HMIWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  url: [host: "127.0.0.1", port: 4002],
  secret_key_base: "7AxUaMlIfj0Z4tOL0yBh5s8SPu64zxaLxFjUqqh6cv6CY1P9TVJjbQc0q93LxeGd",
  server: true,
  live_view: [signing_salt: "ogol_hmi_live_view_test"]

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
