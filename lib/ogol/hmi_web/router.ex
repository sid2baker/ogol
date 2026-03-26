defmodule Ogol.HMIWeb.Router do
  use Ogol.HMIWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Ogol.HMIWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", Ogol.HMIWeb do
    pipe_through(:browser)

    live("/", OverviewLive, :index)
  end
end
