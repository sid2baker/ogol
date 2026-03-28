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

    workspace = build_workspace(params)

    case Bundle.export_current(app_id: app_id, workspace: workspace) do
      {:ok, source} ->
        send_download(conn, {:binary, source},
          filename: "#{app_id}.ogol.ex",
          content_type: "text/plain"
        )

      {:error, reason} ->
        send_resp(conn, 500, "bundle export failed: #{inspect(reason)}")
    end
  end

  defp build_workspace(params) do
    workspace = %{}

    workspace =
      case {params["open_kind"], params["open_id"]} do
        {kind, id} when is_binary(kind) and kind != "" and is_binary(id) and id != "" ->
          case normalize_open_kind(kind) do
            nil -> workspace
            normalized -> Map.put(workspace, :open_artifact, {normalized, id})
          end

        _ ->
          case params["driver_id"] do
            nil -> workspace
            "" -> workspace
            id -> Map.put(workspace, :open_artifact, {:driver, id})
          end
      end

    case params["editor_mode"] do
      "source" -> Map.put(workspace, :editor_mode, :source)
      "visual" -> Map.put(workspace, :editor_mode, :visual)
      _ -> workspace
    end
  end

  defp normalize_open_kind("driver"), do: :driver
  defp normalize_open_kind("hmi_surface"), do: :hmi_surface
  defp normalize_open_kind("surface"), do: :surface
  defp normalize_open_kind(_other), do: nil
end
