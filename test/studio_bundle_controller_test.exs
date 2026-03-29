defmodule Ogol.HMI.StudioBundleControllerTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.{SurfaceDraftStore, StudioWorkspace}
  alias Ogol.TestSupport.HmiStudioTopology
  alias Ogol.Topology.Runtime

  test "downloads the current studio bundle as a single elixir source file" do
    {:ok, pid} = Runtime.start(HmiStudioTopology.__ogol_topology__())
    {:ok, workspace} = StudioWorkspace.active_workspace()

    Enum.each(workspace.cells, fn cell ->
      SurfaceDraftStore.ensure_definition_draft(cell.surface_id, cell.definition,
        source_module: cell.source_module
      )
    end)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

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

    assert conn.resp_body =~ "defmodule Ogol.Bundle.PackagingLine.Draft do"
    assert conn.resp_body =~ "kind: :ogol_revision_bundle"
    assert conn.resp_body =~ "revision: \"draft\""
    assert conn.resp_body =~ "defmodule Ogol.Generated.Drivers.PackagingOutputs do"

    assert conn.resp_body =~
             "defmodule Ogol.HMI.Surfaces.StudioDrafts.Topologies.SimpleHmiLine.Overview do"
  end
end
