defmodule Ogol.HMI.HardwareSupportSnapshotControllerTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.HardwareGateway

  test "downloads a saved support snapshot as json" do
    assert {:ok, snapshot} =
             HardwareGateway.capture_support_snapshot(%{
               context: %{
                 mode: %{kind: :testing, write_policy: :enabled},
                 observed: %{source: :none},
                 summary: %{state: :expected_none}
               },
               ethercat: %{slaves: [], state: {:ok, :idle}},
               events: [],
               saved_configs: []
             })

    conn =
      build_conn()
      |> get("/studio/hardware/support_snapshots/#{snapshot.id}/download")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/json")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "#{snapshot.id}.json"

    assert {:ok, body} = Jason.decode(conn.resp_body)
    assert body["schema"] == "ogol.hardware_support_snapshot.v1"
    assert body["snapshot"]["id"] == snapshot.id
    assert body["snapshot"]["kind"] == "support"
    assert body["snapshot"]["summary"]["state"] == "expected_none"
  end
end
