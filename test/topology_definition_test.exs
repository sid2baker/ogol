defmodule Ogol.Studio.TopologyDefinitionTest do
  use ExUnit.Case, async: false

  alias Ogol.Studio.TopologyDefinition

  test "cast_model validates a constrained topology authoring subset" do
    assert {:ok, model} =
             TopologyDefinition.cast_model(%{
               "topology_id" => "packaging_line",
               "module_name" => "Ogol.Generated.Topologies.PackagingLine",
               "root_machine" => "packaging_line",
               "strategy" => "rest_for_one",
               "meaning" => "Packaging line topology",
               "machine_count" => "2",
               "observation_count" => "2",
               "machines" => %{
                 "0" => %{
                   "name" => "packaging_line",
                   "module_name" => "Ogol.Generated.Machines.PackagingLine",
                   "restart" => "permanent",
                   "meaning" => "Packaging line coordinator"
                 },
                 "1" => %{
                   "name" => "inspection_cell",
                   "module_name" => "Ogol.Generated.Machines.InspectionCell",
                   "restart" => "transient",
                   "meaning" => "Inspection coordinator"
                 }
               },
               "observations" => %{
                 "0" => %{
                   "kind" => "signal",
                   "source" => "inspection_cell",
                   "item" => "faulted",
                   "as" => "inspection_faulted",
                   "meaning" => "Inspection fault forwarded"
                 },
                 "1" => %{
                   "kind" => "down",
                   "source" => "inspection_cell",
                   "item" => "",
                   "as" => "inspection_down",
                   "meaning" => "Inspection node down"
                 }
               }
             })

    assert model.strategy == "rest_for_one"
    assert Enum.map(model.machines, & &1.name) == ["packaging_line", "inspection_cell"]
    assert Enum.map(model.observations, & &1.kind) == ["signal", "down"]
  end

  test "generated topology source round-trips through the supported subset" do
    model = TopologyDefinition.default_model("packaging_line")
    source = TopologyDefinition.to_source(model)

    assert {:ok, parsed} = TopologyDefinition.from_source(source)
    assert parsed == model
  end

  test "source with unsupported topology features falls back to source-only" do
    source = """
    defmodule Ogol.Generated.Topologies.PackagingLine do
      use Ogol.Topology
      alias Custom.Helper

      topology do
        root(:packaging_line)
      end

      machines do
        machine(:packaging_line, Ogol.Generated.Machines.PackagingLine)
      end
    end
    """

    assert {:error, diagnostics} = TopologyDefinition.from_source(source)
    assert Enum.any?(diagnostics, &String.contains?(&1, "unsupported top-level constructs"))
  end

  test "syntax errors are normalized into string diagnostics" do
    source = """
    defmodule Ogol.Generated.Topologies.PackagingLine do
      use Ogol.Topology

      topology do
        root(:packaging_line)
    end
    """

    assert {:error, diagnostics} = TopologyDefinition.from_source(source)
    assert Enum.all?(diagnostics, &is_binary/1)
    assert Enum.any?(diagnostics, &String.starts_with?(&1, "line "))
  end
end
