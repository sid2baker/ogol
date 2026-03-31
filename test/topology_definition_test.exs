defmodule Ogol.Topology.SourceTest do
  use ExUnit.Case, async: false

  alias Ogol.Topology.Source, as: TopologySource

  test "cast_model validates a constrained topology authoring subset" do
    assert {:ok, model} =
             TopologySource.cast_model(%{
               "topology_id" => "packaging_line",
               "module_name" => "Ogol.Generated.Topologies.PackagingLine",
               "strategy" => "rest_for_one",
               "meaning" => "Packaging line topology",
               "machine_count" => "2",
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
               }
             })

    assert model.strategy == "rest_for_one"
    assert Enum.map(model.machines, & &1.name) == ["packaging_line", "inspection_cell"]
  end

  test "generated topology source round-trips through the supported subset" do
    model = TopologySource.default_model("packaging_line")
    source = TopologySource.to_source(model)

    assert {:ok, parsed} = TopologySource.from_source(source)
    assert parsed == model
  end

  test "source with unsupported topology features falls back to source-only" do
    source = """
    defmodule Ogol.Generated.Topologies.PackagingLine do
      use Ogol.Topology
      alias Custom.Helper

      topology do
        strategy(:one_for_one)
      end

      machines do
        machine(:packaging_line, Ogol.Generated.Machines.PackagingLine)
      end
    end
    """

    assert {:error, diagnostics} = TopologySource.from_source(source)

    assert Enum.any?(
             diagnostics,
             &String.contains?(&1, "must only define `use`, `topology`, and `machines`")
           )
  end

  test "syntax errors are normalized into string diagnostics" do
    source = """
    defmodule Ogol.Generated.Topologies.PackagingLine do
      use Ogol.Topology

      topology do
        strategy(:one_for_one)
    end
    """

    assert {:error, diagnostics} = TopologySource.from_source(source)
    assert Enum.all?(diagnostics, &is_binary/1)
    assert Enum.any?(diagnostics, &String.contains?(&1, "missing terminator: end"))
  end
end
