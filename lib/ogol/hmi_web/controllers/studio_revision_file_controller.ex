defmodule Ogol.HMIWeb.StudioRevisionFileController do
  use Ogol.HMIWeb, :controller

  alias Ogol.Studio.RevisionFile

  def download(conn, params) do
    app_id =
      params
      |> Map.get("app_id", "ogol")
      |> to_string()
      |> String.trim()
      |> case do
        "" -> "ogol"
        value -> value
      end

    case RevisionFile.export_current(app_id: app_id) do
      {:ok, source} ->
        send_download(conn, {:binary, source},
          filename: "#{app_id}.ogol.ex",
          content_type: "text/plain"
        )

      {:error, reason} ->
        send_resp(conn, 500, "revision file export failed: #{inspect(reason)}")
    end
  end
end
