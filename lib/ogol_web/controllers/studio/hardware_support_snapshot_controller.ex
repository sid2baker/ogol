defmodule OgolWeb.Studio.HardwareSupportSnapshotController do
  use OgolWeb, :controller

  alias Ogol.Runtime.Hardware.Gateway, as: HardwareGateway

  def download(conn, %{"id" => id}) do
    case HardwareGateway.get_support_snapshot(id) do
      nil ->
        send_resp(conn, 404, "support snapshot not found")

      snapshot ->
        body =
          %{
            schema: "ogol.hardware_support_snapshot.v1",
            snapshot: json_safe(snapshot)
          }
          |> Jason.encode_to_iodata!(pretty: true)

        send_download(conn, {:binary, body},
          filename: "#{snapshot.id}.json",
          content_type: "application/json"
        )
    end
  end

  defp json_safe(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> json_safe()
  end

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(value), do: inspect(value)
end
