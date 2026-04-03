defmodule Ogol.HMI.Surface.Studio.CellTest do
  use ExUnit.Case, async: true

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.Compiler.Analysis
  alias Ogol.HMI.Surface.Studio.Cell, as: HmiSurfaceCell
  alias Ogol.HMI.Surface.RuntimeStore.Entry
  alias Ogol.Studio.Cell
  alias Ogol.Session.Workspace.SourceDraft

  test "source-only HMI falls back to source view and disables compile" do
    facts =
      HmiSurfaceCell.facts_from_assigns(%{
        cell: %SourceDraft{id: "surface_one"},
        draft_source: "defmodule Example do end",
        current_source_digest: Ogol.Studio.Build.digest("defmodule Example do end"),
        source_analysis: %Analysis{
          source: "defmodule Example do end",
          parse_status: :ok,
          classification: :dsl_only,
          validation_status: :unknown,
          compile_status: :blocked,
          diagnostics: ["Managed visual subset no longer matches this source."]
        },
        surface_runtime_entry: %Entry{surface_id: "surface_one"},
        current_assignment: %{surface_id: :operations_overview},
        studio_feedback: nil,
        requested_view: :configuration
      })

    derived = Cell.derive(HmiSurfaceCell, facts)

    assert derived.selected_view == :source
    assert Enum.any?(derived.views, &(&1.id == :configuration and not &1.available?))
    assert Enum.any?(derived.views, &(&1.id == :preview and not &1.available?))
    assert derived.notice.title == "Source-only mode"
    assert [%{id: :compile, enabled?: false}, %{id: :delete, enabled?: true}] = derived.controls
  end

  test "compiled HMI exposes deploy" do
    facts =
      HmiSurfaceCell.facts_from_assigns(%{
        cell: %SourceDraft{id: "surface_one"},
        draft_source: "use Ogol.HMI.Surface",
        current_source_digest: Ogol.Studio.Build.digest("use Ogol.HMI.Surface"),
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
        surface_runtime_entry: %Entry{
          surface_id: "surface_one",
          compiled_version: "r1",
          compiled_source_digest: Ogol.Studio.Build.digest("use Ogol.HMI.Surface")
        },
        current_assignment: %{surface_id: :operations_overview},
        studio_feedback: nil,
        requested_view: :configuration
      })

    derived = Cell.derive(HmiSurfaceCell, facts)

    assert derived.selected_view == :configuration
    assert Enum.map(derived.controls, & &1.id) == [:recompile, :deploy, :delete]
    assert derived.notice.title == "Compiled"
  end
end
