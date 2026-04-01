defmodule OgolWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :ogol

  @session_options [
    store: :cookie,
    key: "_ogol_key",
    signing_salt: "ogol_session"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :ogol,
    gzip: false,
    only: OgolWeb.static_paths()
  )

  if Mix.env() == :dev do
    plug(Tidewave)
  end

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)

    plug(Phoenix.CodeReloader)
    plug(Phoenix.LiveReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(OgolWeb.Router)
end
