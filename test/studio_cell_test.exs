defmodule Ogol.Studio.CellTest do
  use ExUnit.Case, async: true

  alias Ogol.Studio.Cell
  alias Ogol.Studio.Cell.Action
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

  test "action_for_transition resolves actions by atom or string id" do
    derived =
      %Derived{
        actions: [
          %Action{id: :compile, label: "Compile", operation: {:compile_artifact, :machine, "m1"}}
        ]
      }

    assert %Action{id: :compile} = Cell.action_for_transition(derived, :compile)
    assert %Action{id: :compile} = Cell.action_for_transition(derived, "compile")
    assert Cell.action_for_transition(derived, "missing") == nil
  end
end
