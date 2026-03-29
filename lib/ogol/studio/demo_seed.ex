defmodule Ogol.Studio.DemoSeed do
  @moduledoc false

  alias EtherCAT.Driver.{EK1100, EL1809, EL2809}
  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias Ogol.HMI.HardwareConfig
  alias Ogol.Studio.{MachineDefinition, TopologyDefinition}

  @default_bind_ip {127, 0, 0, 1}
  @default_simulator_ip {127, 0, 0, 2}
  @default_domain [
    id: :main,
    cycle_time_us: 1_000,
    miss_threshold: 1_000,
    recovery_threshold: 3
  ]

  @machine_ids [
    "pack_and_inspect_cell",
    "infeed_conveyor",
    "clamp_station",
    "inspection_station",
    "reject_gate"
  ]

  @topology_ids ["pack_and_inspect_cell"]

  @unsupported_transition_actions_message "transition guards, priorities, reentry, or actions require source editing"

  @spec machine_ids() :: [String.t()]
  def machine_ids, do: @machine_ids

  @spec topology_ids() :: [String.t()]
  def topology_ids, do: @topology_ids

  @spec machine_draft(String.t()) :: map() | nil
  def machine_draft("pack_and_inspect_cell") do
    model = pack_and_inspect_cell_shadow_model()

    %{
      model: model,
      source: pack_and_inspect_cell_source(),
      sync_state: :unsupported,
      sync_diagnostics: [@unsupported_transition_actions_message]
    }
  end

  def machine_draft("infeed_conveyor") do
    model =
      MachineDefinition.default_model("infeed_conveyor")
      |> Map.put(:meaning, "Infeed conveyor stop")
      |> Map.put(:requests, [%{name: "feed_part"}, %{name: "reset"}])
      |> Map.put(:signals, [])
      |> Map.put(:states, [
        %{name: "idle", initial?: true, status: "Idle", meaning: "Waiting for a part"},
        %{name: "positioned", initial?: false, status: "Positioned", meaning: "Part staged"}
      ])
      |> Map.put(:transitions, [
        %{
          source: "idle",
          family: "request",
          trigger: "feed_part",
          destination: "positioned",
          meaning: "Stage one part at the clamp stop"
        },
        %{
          source: "positioned",
          family: "request",
          trigger: "reset",
          destination: "idle",
          meaning: "Clear the staged part"
        },
        %{
          source: "idle",
          family: "request",
          trigger: "reset",
          destination: "idle",
          meaning: "Keep the infeed ready"
        }
      ])

    synced_machine_draft(model)
  end

  def machine_draft("clamp_station") do
    model =
      MachineDefinition.default_model("clamp_station")
      |> Map.put(:meaning, "Clamp station")
      |> Map.put(:requests, [%{name: "close"}, %{name: "open"}])
      |> Map.put(:signals, [])
      |> Map.put(:states, [
        %{name: "open", initial?: true, status: "Open", meaning: "Clamp released"},
        %{name: "closed", initial?: false, status: "Closed", meaning: "Clamp engaged"}
      ])
      |> Map.put(:transitions, [
        %{
          source: "open",
          family: "request",
          trigger: "close",
          destination: "closed",
          meaning: "Clamp the staged part"
        },
        %{
          source: "closed",
          family: "request",
          trigger: "open",
          destination: "open",
          meaning: "Release the clamp"
        },
        %{
          source: "open",
          family: "request",
          trigger: "open",
          destination: "open",
          meaning: "Keep the clamp released"
        }
      ])

    synced_machine_draft(model)
  end

  def machine_draft("inspection_station") do
    model =
      MachineDefinition.default_model("inspection_station")
      |> Map.put(:meaning, "Inspection station")
      |> Map.put(:requests, [%{name: "pass_part"}, %{name: "reject_part"}, %{name: "reset"}])
      |> Map.put(:signals, [])
      |> Map.put(:states, [
        %{name: "idle", initial?: true, status: "Ready", meaning: "Waiting for inspection input"},
        %{name: "passed", initial?: false, status: "Passed", meaning: "Part accepted"},
        %{name: "failed", initial?: false, status: "Rejected", meaning: "Part rejected"}
      ])
      |> Map.put(:transitions, [
        %{
          source: "idle",
          family: "request",
          trigger: "pass_part",
          destination: "passed",
          meaning: "Accept the current part"
        },
        %{
          source: "idle",
          family: "request",
          trigger: "reject_part",
          destination: "failed",
          meaning: "Reject the current part"
        },
        %{
          source: "passed",
          family: "request",
          trigger: "reset",
          destination: "idle",
          meaning: "Prepare for the next inspection"
        },
        %{
          source: "failed",
          family: "request",
          trigger: "reset",
          destination: "idle",
          meaning: "Prepare for the next inspection"
        },
        %{
          source: "idle",
          family: "request",
          trigger: "reset",
          destination: "idle",
          meaning: "Keep the station ready"
        }
      ])

    synced_machine_draft(model)
  end

  def machine_draft("reject_gate") do
    model =
      MachineDefinition.default_model("reject_gate")
      |> Map.put(:meaning, "Reject gate actuator")
      |> Map.put(:requests, [%{name: "reject"}, %{name: "reset"}])
      |> Map.put(:signals, [])
      |> Map.put(:states, [
        %{name: "idle", initial?: true, status: "Ready", meaning: "Reject path clear"},
        %{name: "latched", initial?: false, status: "Rejecting", meaning: "Reject gate active"}
      ])
      |> Map.put(:transitions, [
        %{
          source: "idle",
          family: "request",
          trigger: "reject",
          destination: "latched",
          meaning: "Open the reject path"
        },
        %{
          source: "latched",
          family: "request",
          trigger: "reset",
          destination: "idle",
          meaning: "Clear the reject latch"
        },
        %{
          source: "idle",
          family: "request",
          trigger: "reset",
          destination: "idle",
          meaning: "Keep the reject path clear"
        }
      ])

    synced_machine_draft(model)
  end

  def machine_draft(_id), do: nil

  @spec topology_draft(String.t()) :: map() | nil
  def topology_draft("pack_and_inspect_cell") do
    model = pack_and_inspect_topology_model()

    %{
      model: model,
      source: TopologyDefinition.to_source(model),
      sync_state: :synced,
      sync_diagnostics: []
    }
  end

  def topology_draft(_id), do: nil

  @spec simulation_configs() :: [HardwareConfig.t()]
  def simulation_configs do
    [ethercat_demo_config(), pack_and_inspect_cell_config()]
  end

  defp synced_machine_draft(model) do
    %{
      model: model,
      source: MachineDefinition.to_source(model),
      sync_state: :synced,
      sync_diagnostics: []
    }
  end

  defp pack_and_inspect_cell_shadow_model do
    MachineDefinition.default_model("pack_and_inspect_cell")
    |> Map.put(:meaning, "Pack and inspect cell coordinator")
    |> Map.put(:requests, [%{name: "start_cycle"}, %{name: "reset_cell"}])
    |> Map.put(:events, [
      %{name: "part_arrived"},
      %{name: "clamp_ready"},
      %{name: "inspection_passed"},
      %{name: "inspection_failed"},
      %{name: "dependency_down"}
    ])
    |> Map.put(:signals, [
      %{name: "cycle_started"},
      %{name: "part_staged"},
      %{name: "clamp_verified"},
      %{name: "cycle_passed"},
      %{name: "cycle_rejected"},
      %{name: "cell_reset"},
      %{name: "dependency_fault"}
    ])
    |> Map.put(:dependencies, [
      %{
        name: "infeed_conveyor",
        meaning: "Stages one part into the cell",
        skills: ["feed_part", "reset"],
        signals: [],
        status: []
      },
      %{
        name: "clamp_station",
        meaning: "Closes the clamp around the staged part",
        skills: ["close", "open"],
        signals: [],
        status: []
      },
      %{
        name: "inspection_station",
        meaning: "Allows the operator to accept or reject the part",
        skills: ["pass_part", "reject_part", "reset"],
        signals: [],
        status: []
      },
      %{
        name: "reject_gate",
        meaning: "Latches the reject path when a part fails inspection",
        skills: ["reject", "reset"],
        signals: [],
        status: []
      }
    ])
    |> Map.put(:states, [
      %{name: "idle", initial?: true, status: "Idle", meaning: "Ready for a new cycle"},
      %{name: "feeding", initial?: false, status: "Feeding", meaning: "Calling the infeed"},
      %{name: "clamping", initial?: false, status: "Clamping", meaning: "Closing the clamp"},
      %{
        name: "awaiting_inspection",
        initial?: false,
        status: "Awaiting inspection",
        meaning: "Waiting for an accept or reject decision"
      },
      %{name: "passed", initial?: false, status: "Passed", meaning: "Cycle completed"},
      %{name: "rejected", initial?: false, status: "Rejected", meaning: "Reject path active"},
      %{name: "fault", initial?: false, status: "Fault", meaning: "A dependency dropped out"}
    ])
    |> Map.put(:transitions, [
      %{
        source: "idle",
        family: "request",
        trigger: "start_cycle",
        destination: "feeding",
        meaning: "Begin a new pack and inspect cycle"
      },
      %{
        source: "feeding",
        family: "event",
        trigger: "part_arrived",
        destination: "clamping",
        meaning: "Continue once the part is staged"
      },
      %{
        source: "clamping",
        family: "event",
        trigger: "clamp_ready",
        destination: "awaiting_inspection",
        meaning: "Hand off to manual inspection"
      },
      %{
        source: "awaiting_inspection",
        family: "event",
        trigger: "inspection_passed",
        destination: "passed",
        meaning: "Complete an accepted cycle"
      },
      %{
        source: "awaiting_inspection",
        family: "event",
        trigger: "inspection_failed",
        destination: "rejected",
        meaning: "Latch the reject path"
      },
      %{
        source: "passed",
        family: "request",
        trigger: "reset_cell",
        destination: "idle",
        meaning: "Reset after a passed cycle"
      },
      %{
        source: "rejected",
        family: "request",
        trigger: "reset_cell",
        destination: "idle",
        meaning: "Reset after a rejected cycle"
      },
      %{
        source: "fault",
        family: "request",
        trigger: "reset_cell",
        destination: "idle",
        meaning: "Recover after a dependency fault"
      },
      %{
        source: "idle",
        family: "request",
        trigger: "reset_cell",
        destination: "idle",
        meaning: "Keep the cell ready"
      },
      %{
        source: "feeding",
        family: "event",
        trigger: "dependency_down",
        destination: "fault",
        meaning: "Drop to fault when a dependency exits"
      },
      %{
        source: "clamping",
        family: "event",
        trigger: "dependency_down",
        destination: "fault",
        meaning: "Drop to fault when a dependency exits"
      },
      %{
        source: "awaiting_inspection",
        family: "event",
        trigger: "dependency_down",
        destination: "fault",
        meaning: "Drop to fault when a dependency exits"
      }
    ])
  end

  defp pack_and_inspect_cell_source do
    """
    defmodule Ogol.Generated.Machines.PackAndInspectCell do
      use Ogol.Machine

      machine do
        name(:pack_and_inspect_cell)
        meaning("Pack and inspect cell coordinator")
      end

      uses do
        dependency(:infeed_conveyor, skills: [:feed_part, :reset])
        dependency(:clamp_station, skills: [:close, :open])
        dependency(:inspection_station, skills: [:pass_part, :reject_part, :reset])
        dependency(:reject_gate, skills: [:reject, :reset])
      end

      boundary do
        request(:start_cycle)
        request(:reset_cell)
        event(:part_arrived)
        event(:clamp_ready)
        event(:inspection_passed)
        event(:inspection_failed)
        event(:dependency_down)
        signal(:cycle_started)
        signal(:part_staged)
        signal(:clamp_verified)
        signal(:cycle_passed)
        signal(:cycle_rejected)
        signal(:cell_reset)
        signal(:dependency_fault)
      end

      states do
        state :idle do
          initial?(true)
          status("Idle")
          meaning("Ready for a new cycle")
        end

        state :feeding do
          status("Feeding")
          meaning("Calling the infeed")
        end

        state :clamping do
          status("Clamping")
          meaning("Closing the clamp")
        end

        state :awaiting_inspection do
          status("Awaiting inspection")
          meaning("Waiting for an accept or reject decision")
        end

        state :passed do
          status("Passed")
          meaning("Cycle completed")
        end

        state :rejected do
          status("Rejected")
          meaning("Reject path active")
        end

        state :fault do
          status("Fault")
          meaning("A dependency dropped out")
        end
      end

      transitions do
        transition :idle, :feeding do
          on({:request, :start_cycle})
          signal(:cycle_started)
          invoke(:infeed_conveyor, :feed_part)
          reply(:ok)
        end

        transition :feeding, :clamping do
          on({:event, :part_arrived})
          signal(:part_staged)
          invoke(:clamp_station, :close)
        end

        transition :clamping, :awaiting_inspection do
          on({:event, :clamp_ready})
          signal(:clamp_verified)
        end

        transition :awaiting_inspection, :passed do
          on({:event, :inspection_passed})
          signal(:cycle_passed)
        end

        transition :awaiting_inspection, :rejected do
          on({:event, :inspection_failed})
          invoke(:reject_gate, :reject)
          signal(:cycle_rejected)
        end

        transition :passed, :idle do
          on({:request, :reset_cell})
          invoke(:infeed_conveyor, :reset)
          invoke(:clamp_station, :open)
          invoke(:inspection_station, :reset)
          invoke(:reject_gate, :reset)
          signal(:cell_reset)
          reply(:ok)
        end

        transition :rejected, :idle do
          on({:request, :reset_cell})
          invoke(:infeed_conveyor, :reset)
          invoke(:clamp_station, :open)
          invoke(:inspection_station, :reset)
          invoke(:reject_gate, :reset)
          signal(:cell_reset)
          reply(:ok)
        end

        transition :fault, :idle do
          on({:request, :reset_cell})
          invoke(:infeed_conveyor, :reset)
          invoke(:clamp_station, :open)
          invoke(:inspection_station, :reset)
          invoke(:reject_gate, :reset)
          signal(:cell_reset)
          reply(:ok)
        end

        transition :idle, :idle do
          on({:request, :reset_cell})
          invoke(:infeed_conveyor, :reset)
          invoke(:clamp_station, :open)
          invoke(:inspection_station, :reset)
          invoke(:reject_gate, :reset)
          signal(:cell_reset)
          reply(:ok)
        end

        transition :feeding, :fault do
          on({:event, :dependency_down})
          signal(:dependency_fault)
        end

        transition :clamping, :fault do
          on({:event, :dependency_down})
          signal(:dependency_fault)
        end

        transition :awaiting_inspection, :fault do
          on({:event, :dependency_down})
          signal(:dependency_fault)
        end
      end
    end
    """
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  defp pack_and_inspect_topology_model do
    %{
      topology_id: "pack_and_inspect_cell",
      module_name: "Ogol.Generated.Topologies.PackAndInspectCell",
      root_machine: "pack_and_inspect_cell",
      strategy: "one_for_one",
      meaning: "Pack and inspect cell topology",
      machines: [
        %{
          name: "pack_and_inspect_cell",
          module_name: "Ogol.Generated.Machines.PackAndInspectCell",
          restart: "permanent",
          meaning: "Pack and inspect cell coordinator"
        },
        %{
          name: "infeed_conveyor",
          module_name: "Ogol.Generated.Machines.InfeedConveyor",
          restart: "transient",
          meaning: "Infeed conveyor stop"
        },
        %{
          name: "clamp_station",
          module_name: "Ogol.Generated.Machines.ClampStation",
          restart: "transient",
          meaning: "Clamp station"
        },
        %{
          name: "inspection_station",
          module_name: "Ogol.Generated.Machines.InspectionStation",
          restart: "transient",
          meaning: "Inspection station"
        },
        %{
          name: "reject_gate",
          module_name: "Ogol.Generated.Machines.RejectGate",
          restart: "transient",
          meaning: "Reject gate actuator"
        }
      ],
      observations: [
        %{
          kind: "state",
          source: "infeed_conveyor",
          item: "positioned",
          as: "part_arrived",
          meaning: "Root sees the part staged"
        },
        %{
          kind: "state",
          source: "clamp_station",
          item: "closed",
          as: "clamp_ready",
          meaning: "Root sees the clamp engaged"
        },
        %{
          kind: "state",
          source: "inspection_station",
          item: "passed",
          as: "inspection_passed",
          meaning: "Root sees an accepted part"
        },
        %{
          kind: "state",
          source: "inspection_station",
          item: "failed",
          as: "inspection_failed",
          meaning: "Root sees a rejected part"
        },
        %{kind: "down", source: "infeed_conveyor", item: nil, as: "dependency_down", meaning: ""},
        %{kind: "down", source: "clamp_station", item: nil, as: "dependency_down", meaning: ""},
        %{
          kind: "down",
          source: "inspection_station",
          item: nil,
          as: "dependency_down",
          meaning: ""
        },
        %{kind: "down", source: "reject_gate", item: nil, as: "dependency_down", meaning: ""}
      ]
    }
  end

  defp ethercat_demo_config do
    simulation_config("ethercat_demo", "EtherCAT Demo Ring")
  end

  defp pack_and_inspect_cell_config do
    simulation_config("pack_and_inspect_cell", "Pack and Inspect Cell Ring")
  end

  defp simulation_config(id, label) do
    now = System.system_time(:millisecond)
    form = simulation_form(id, label)

    %HardwareConfig{
      id: id,
      protocol: :ethercat,
      label: label,
      inserted_at: now,
      updated_at: now,
      spec: %{
        bind_ip: @default_bind_ip,
        simulator_ip: @default_simulator_ip,
        domains: [@default_domain],
        scan_stable_ms: 20,
        scan_poll_ms: 10,
        frame_timeout_ms: 20,
        slaves: [
          %SlaveConfig{
            name: :coupler,
            driver: EK1100,
            process_data: :none,
            target_state: :op,
            health_poll_ms: nil
          },
          %SlaveConfig{
            name: :inputs,
            driver: EL1809,
            process_data: {:all, :main},
            target_state: :op,
            health_poll_ms: nil
          },
          %SlaveConfig{
            name: :outputs,
            driver: EL2809,
            process_data: {:all, :main},
            target_state: :op,
            health_poll_ms: nil
          }
        ]
      },
      meta: %{form: form}
    }
  end

  defp simulation_form(id, label) do
    %{
      "id" => id,
      "label" => label,
      "bind_ip" => "127.0.0.1",
      "simulator_ip" => "127.0.0.2",
      "scan_stable_ms" => "20",
      "scan_poll_ms" => "10",
      "frame_timeout_ms" => "20",
      "domains" => [
        %{
          "id" => "main",
          "cycle_time_us" => "1000",
          "miss_threshold" => "1000",
          "recovery_threshold" => "3"
        }
      ],
      "slaves" => [
        %{
          "name" => "coupler",
          "driver" => "EtherCAT.Driver.EK1100",
          "target_state" => "op",
          "process_data_mode" => "none",
          "process_data_domain" => "",
          "health_poll_ms" => ""
        },
        %{
          "name" => "inputs",
          "driver" => "EtherCAT.Driver.EL1809",
          "target_state" => "op",
          "process_data_mode" => "all",
          "process_data_domain" => "main",
          "health_poll_ms" => ""
        },
        %{
          "name" => "outputs",
          "driver" => "EtherCAT.Driver.EL2809",
          "target_state" => "op",
          "process_data_mode" => "all",
          "process_data_domain" => "main",
          "health_poll_ms" => ""
        }
      ]
    }
  end
end
