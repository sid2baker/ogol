defmodule Ogol.HMI.StudioRevisionFileControllerTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.SurfaceDefaults
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.TestSupport.HmiStudioTopology
  alias Ogol.Topology.Runtime

  test "downloads the current studio revision as a single elixir source file" do
    {:ok, pid} = Runtime.start(HmiStudioTopology.__ogol_topology__())

    WorkspaceStore.replace_hmi_surfaces(
      SurfaceDefaults.drafts_from_topology(HmiStudioTopology.__ogol_topology__())
    )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

    conn =
      build_conn()
      |> get("/studio/revision_file/download", %{
        "app_id" => "packaging_line"
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/plain"]

    [content_disposition] = get_resp_header(conn, "content-disposition")
    assert content_disposition =~ "attachment"
    assert content_disposition =~ "packaging_line.ogol.ex"

    assert conn.resp_body =~ "defmodule Ogol.RevisionFile.PackagingLine.Draft do"
    assert conn.resp_body =~ "kind: :ogol_revision"
    assert conn.resp_body =~ "revision: \"draft\""
    assert conn.resp_body =~ "defmodule Ogol.Generated.Drivers.PackagingOutputs do"

    assert conn.resp_body =~
             "defmodule Ogol.HMI.Surfaces.StudioDrafts.Topologies.SimpleHmiLine.Overview do"
  end
end
