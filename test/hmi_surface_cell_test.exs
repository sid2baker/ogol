defmodule Ogol.Studio.HmiSurfaceCellTest do
  use ExUnit.Case, async: true

  alias Ogol.HMI.Surface
  alias Ogol.HMI.SurfaceCompiler.Analysis
  alias Ogol.HMI.SurfaceDraftStore.Draft
  alias Ogol.HMI.StudioWorkspace.Cell, as: WorkspaceCell
  alias Ogol.Studio.Cell
  alias Ogol.Studio.HmiSurfaceCell

  test "source-only HMI falls back to source view and disables compile" do
    facts =
      HmiSurfaceCell.facts_from_assigns(%{
        cell: %WorkspaceCell{surface_id: "surface_one"},
        draft_source: "defmodule Example do end",
        source_analysis: %Analysis{
          source: "defmodule Example do end",
          parse_status: :ok,
          classification: :dsl_only,
          validation_status: :unknown,
          compile_status: :blocked,
          diagnostics: ["Managed visual subset no longer matches this source."]
        },
        surface_draft: %Draft{surface_id: "surface_one", source: "defmodule Example do end"},
        current_assignment: %{surface_id: :operations_overview},
        studio_feedback: nil,
        requested_view: :visual
      })

    derived = Cell.derive(HmiSurfaceCell, facts)

    assert derived.selected_view == :source
    assert Enum.any?(derived.views, &(&1.id == :visual and not &1.available?))
    assert derived.notice.title == "Source-only mode"
    assert [%{id: :compile, enabled?: false}] = derived.actions
  end

  test "compiled HMI exposes deploy" do
    facts =
      HmiSurfaceCell.facts_from_assigns(%{
        cell: %WorkspaceCell{surface_id: "surface_one"},
        draft_source: "use Ogol.HMI.Surface",
        source_analysis: %Analysis{
          source: "use Ogol.HMI.Surface",
          parse_status: :ok,
          classification: :visual,
          validation_status: :ok,
          compile_status: :ready,
          diagnostics: [],
          definition: %Surface{},
          runtime: %Surface.Runtime{}
        },
        surface_draft: %Draft{
          surface_id: "surface_one",
          source: "use Ogol.HMI.Surface",
          compiled_version: "r1"
        },
        current_assignment: %{surface_id: :operations_overview},
        studio_feedback: nil,
        requested_view: :visual
      })

    derived = Cell.derive(HmiSurfaceCell, facts)

    assert derived.selected_view == :visual
    assert Enum.map(derived.actions, & &1.id) == [:compile, :deploy]
    assert derived.notice.title == "Compiled"
  end
end
