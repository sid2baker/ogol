defmodule Ogol.Studio.CellTest do
  use ExUnit.Case, async: true

  alias Ogol.Studio.Cell
  alias Ogol.Studio.Cell.Control
  alias Ogol.Studio.Cell.Derived
  alias Ogol.Studio.Cell.Facts
  alias Ogol.Studio.Cell.View

  test "source is the default requested and selected view" do
    assert %Facts{}.requested_view == :source
    assert %Derived{}.selected_view == :source
  end

  test "resolve_views guarantees an available source fallback" do
    {selected_view, views} =
      Cell.resolve_views(:visual, [%View{id: :visual, label: "Visual", available?: false}])

    assert selected_view == :source
    assert Enum.any?(views, &(&1.id == :source and &1.available?))
  end

  test "finalize enforces source fallback even if derived output is invalid" do
    facts = %Facts{requested_view: :visual}

    derived =
      Cell.finalize(
        %Derived{
          selected_view: :visual,
          views: [%View{id: :visual, label: "Visual", available?: false}]
        },
        facts
      )

    assert derived.selected_view == :source
    assert Enum.any?(derived.views, &(&1.id == :source and &1.available?))
  end

  test "control_for_transition resolves controls by atom or string id" do
    derived =
      %Derived{
        controls: [
          %Control{
            id: :compile,
            label: "Compile",
            operation: {:compile_artifact, :machine, "m1"}
          },
          %Control{id: :delete, label: "Delete", operation: {:delete_entry, :machine, "m1"}}
        ]
      }

    assert %Control{id: :compile} = Cell.control_for_transition(derived, :compile)
    assert %Control{id: :compile} = Cell.control_for_transition(derived, "compile")
    assert %Control{id: :delete} = Cell.control_for_transition(derived, "delete")
    assert Cell.control_for_transition(derived, "missing") == nil
  end

  test "module_compile_control switches to recompile once source has been compiled" do
    control =
      Cell.module_compile_control(
        :machine,
        %Facts{artifact_id: "m1", lifecycle_state: :compiled}
      )

    assert control.id == :recompile
    assert control.label == "Recompile"
    assert control.operation == {:compile_artifact, :machine, "m1"}
  end

  test "delete_control carries a workspace operation" do
    control = Cell.delete_control(:machine, %Facts{artifact_id: "m1"})

    assert control.id == :delete
    assert control.operation == {:delete_entry, :machine, "m1"}
  end
end
