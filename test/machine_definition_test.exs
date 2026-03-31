defmodule Ogol.Machine.SourceTest do
  use ExUnit.Case, async: false

  alias Ogol.Machine.Source, as: MachineSource

  test "cast_model validates a constrained machine authoring subset" do
    assert {:ok, model} =
             MachineSource.cast_model(%{
               "machine_id" => "packaging_line",
               "module_name" => "Ogol.Generated.Machines.PackagingLine",
               "meaning" => "Packaging line coordinator",
               "request_count" => "2",
               "event_count" => "1",
               "command_count" => "1",
               "signal_count" => "1",
               "dependency_count" => "1",
               "state_count" => "2",
               "transition_count" => "1",
               "requests" => %{
                 "0" => %{"name" => "start_cycle", "meaning" => ""},
                 "1" => %{"name" => "stop_cycle", "meaning" => ""}
               },
               "events" => %{"0" => %{"name" => "inspection_faulted", "meaning" => ""}},
               "commands" => %{"0" => %{"name" => "start_motor"}},
               "signals" => %{"0" => %{"name" => "started"}},
               "dependencies" => %{
                 "0" => %{
                   "name" => "inspection_cell",
                   "meaning" => "Inspection dependency",
                   "skill_count" => "1",
                   "skills" => %{"0" => %{"name" => "inspect_quality"}},
                   "signal_count" => "1",
                   "signals" => %{"0" => %{"name" => "faulted"}},
                   "status_count" => "2",
                   "status" => %{
                     "0" => %{"name" => "running"},
                     "1" => %{"name" => "faulted"}
                   }
                 }
               },
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
    assert Enum.map(model.events, & &1.name) == ["inspection_faulted"]
    assert Enum.map(model.dependencies, & &1.name) == ["inspection_cell"]
    assert hd(model.dependencies).skills == ["inspect_quality"]
    assert hd(model.dependencies).signals == ["faulted"]
    assert hd(model.dependencies).status == ["faulted", "running"]
    assert Enum.map(model.states, & &1.name) == ["idle", "running"]
  end

  test "generated machine source round-trips through the supported subset" do
    model =
      MachineSource.default_model("packaging_line")
      |> Map.put(:events, [%{name: "inspection_faulted", meaning: "Inspection forwarded"}])
      |> Map.put(:dependencies, [
        %{
          name: "inspection_cell",
          meaning: "Inspection dependency",
          skills: ["inspect_quality"],
          signals: ["faulted"],
          status: ["faulted", "running"]
        }
      ])

    source = MachineSource.to_source(model)

    assert source =~ "reply(:ok)"

    assert {:ok, parsed} = MachineSource.from_source(source)
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

    assert {:error, diagnostics} = MachineSource.from_source(source)
    assert Enum.any?(diagnostics, &String.contains?(&1, "memory fields require source editing"))
  end
end
