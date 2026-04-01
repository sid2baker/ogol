defmodule OgolWeb.PageController do
  use OgolWeb, :controller

  def root(conn, _params) do
    redirect(conn, to: ~p"/ops")
  end
end
