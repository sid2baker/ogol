defmodule Ogol.HMIWeb.PageController do
  use Ogol.HMIWeb, :controller

  def root(conn, _params) do
    redirect(conn, to: ~p"/ops")
  end
end
