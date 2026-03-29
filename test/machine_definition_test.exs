defmodule Ogol.Studio.MachineDefinitionTest do
  use ExUnit.Case, async: false

  alias Ogol.Studio.MachineDefinition

  test "cast_model validates a constrained machine authoring subset" do
    assert {:ok, model} =
             MachineDefinition.cast_model(%{
               "machine_id" => "packaging_line",
               "module_name" => "Ogol.Generated.Machines.PackagingLine",
               "meaning" => "Packaging line coordinator",
               "request_count" => "2",
               "command_count" => "1",
               "signal_count" => "1",
               "state_count" => "2",
               "transition_count" => "1",
               "requests" => %{
                 "0" => %{"name" => "start_cycle"},
                 "1" => %{"name" => "stop_cycle"}
               },
               "commands" => %{"0" => %{"name" => "start_motor"}},
               "signals" => %{"0" => %{"name" => "started"}},
               "states" => %{
                 "0" => %{"name" => "idle", "initial?" => "true", "status" => "Idle"},
                 "1" => %{"name" => "running", "initial?" => "false", "status" => "Running"}
               },
               "transitions" => %{
                 "0" => %{
                   "source" => "idle",
                   "family" => "request",
                   "trigger" => "start_cycle",
                   "destination" => "running"
                 }
               }
             })

    assert model.machine_id == "packaging_line"
    assert Enum.map(model.requests, & &1.name) == ["start_cycle", "stop_cycle"]
    assert Enum.map(model.states, & &1.name) == ["idle", "running"]
  end

  test "generated machine source round-trips through the supported subset" do
    model = MachineDefinition.default_model("packaging_line")
    source = MachineDefinition.to_source(model)

    assert {:ok, parsed} = MachineDefinition.from_source(source)
    assert parsed == model
  end

  test "source with unsupported machine features falls back to source-only" do
    source = """
    defmodule Ogol.Generated.Machines.PackagingLine do
      use Ogol.Machine

      machine do
        name(:packaging_line)
      end

      memory do
        field(:retry_count, :integer, default: 0)
      end
    end
    """

    assert {:error, diagnostics} = MachineDefinition.from_source(source)
    assert Enum.any?(diagnostics, &String.contains?(&1, "memory fields require source editing"))
  end
end
