import Config

config :ogol, Ogol.HMIWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "7AxUaMlIfj0Z4tOL0yBh5s8SPu64zxaLxFjUqqh6cv6CY1P9TVJjbQc0q93LxeGd",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:ogol_hmi, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:ogol_hmi, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/ogol/hmi_web/(controllers|live|components|router|telemetry)/.*(ex|heex)$",
      ~r"lib/ogol/hmi_web.ex$",
      ~r"lib/ogol/hmi/.*(ex)$"
    ]
  ]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
