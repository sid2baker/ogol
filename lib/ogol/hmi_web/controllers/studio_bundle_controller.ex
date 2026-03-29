defmodule Ogol.HMIWeb.StudioBundleController do
  use Ogol.HMIWeb, :controller

  alias Ogol.Studio.Bundle

  def download(conn, params) do
    app_id =
      params
      |> Map.get("app_id", "ogol_bundle")
      |> to_string()
      |> String.trim()
      |> case do
        "" -> "ogol_bundle"
        value -> value
      end

    case Bundle.export_current(app_id: app_id) do
      {:ok, source} ->
        send_download(conn, {:binary, source},
          filename: "#{app_id}.ogol.ex",
          content_type: "text/plain"
        )

      {:error, reason} ->
        send_resp(conn, 500, "bundle export failed: #{inspect(reason)}")
    end
  end
end
