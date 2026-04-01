import Config

test_port = String.to_integer(System.get_env("OGOL_TEST_PORT") || "4002")

config :ogol, OgolWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: test_port],
  url: [host: "127.0.0.1", port: test_port],
  secret_key_base: "7AxUaMlIfj0Z4tOL0yBh5s8SPu64zxaLxFjUqqh6cv6CY1P9TVJjbQc0q93LxeGd",
  server: true,
  live_view: [signing_salt: "ogol_live_view_test"]

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

config :ogol, Ogol.Studio.Revisions,
  root: Path.join(System.tmp_dir!(), "ogol_test_revisions_#{test_port}")
