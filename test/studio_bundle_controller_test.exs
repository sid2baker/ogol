defmodule Ogol.HMI.StudioBundleControllerTest do
  use Ogol.ConnCase, async: false

  test "downloads the current studio bundle as a single elixir source file" do
    :ok =
      Ogol.HMI.HardwareConfigStore.put_config(%Ogol.HMI.HardwareConfig{
        id: "ethercat_demo",
        protocol: :ethercat,
        label: "EtherCAT Demo Ring",
        spec: %{slaves: [], domains: []},
        meta: %{}
      })

    conn =
      build_conn()
      |> get("/studio/bundle/download", %{
        "app_id" => "packaging_line"
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/plain"]

    [content_disposition] = get_resp_header(conn, "content-disposition")
    assert content_disposition =~ "attachment"
    assert content_disposition =~ "packaging_line.ogol.ex"

    assert conn.resp_body =~ "defmodule Ogol.Bundle.PackagingLine do"
    assert conn.resp_body =~ "defmodule Ogol.Generated.Drivers.PackagingOutputs do"
    assert conn.resp_body =~ "defmodule Ogol.HMI.Surfaces.StudioDrafts.OperationsOverview do"
    assert conn.resp_body =~ "defmodule Ogol.Generated.HardwareConfigs.EthercatDemo do"
  end
end
