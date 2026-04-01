defmodule Ogol.Studio.DemoSeed do
  @moduledoc false

  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias Ogol.Hardware.Config, as: HardwareConfig
  alias Ogol.Hardware.Config.EtherCAT
  alias Ogol.Hardware.Config.EtherCAT.{Domain, Timing, Transport}
  alias Ogol.Hardware.EtherCAT.Driver.{EK1100, EL1809, EL2809}
  alias Ogol.Machine.Form, as: MachineForm
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Topology.Source, as: TopologySource

  @default_bind_ip {127, 0, 0, 1}
  @default_simulator_ip {127, 0, 0, 2}
  @default_domain %Domain{
    id: :main,
    cycle_time_us: 1_000,
    miss_threshold: 1_000,
    recovery_threshold: 3
  }

  @machine_ids [
    "infeed_conveyor",
    "clamp_station",
    "inspection_station",
    "reject_gate"
  ]

  @topology_ids ["pack_and_inspect_cell"]

  @spec machine_ids() :: [String.t()]
  def machine_ids, do: @machine_ids

  @spec topology_ids() :: [String.t()]
  def topology_ids, do: @topology_ids

  @spec machine_draft(String.t()) :: map() | nil
  def machine_draft("infeed_conveyor") do
    model =
      MachineForm.default_model("infeed_conveyor")
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
      MachineForm.default_model("clamp_station")
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
      MachineForm.default_model("inspection_station")
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
      MachineForm.default_model("reject_gate")
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
      source: TopologySource.to_source(model),
      sync_state: :synced,
      sync_diagnostics: []
    }
  end

  def topology_draft(_id), do: nil

  @spec simulation_configs() :: [HardwareConfig.t()]
  def simulation_configs do
    [ethercat_demo_config(), pack_and_inspect_cell_config()]
  end

  @spec default_hardware_config() :: HardwareConfig.t()
  def default_hardware_config do
    ethercat_demo_config()
  end

  defp synced_machine_draft(model) do
    %{
      model: model,
      source: MachineSource.to_source(model),
      sync_state: :synced,
      sync_diagnostics: []
    }
  end

  defp pack_and_inspect_topology_model do
    %{
      topology_id: "pack_and_inspect_cell",
      module_name: "Ogol.Generated.Topologies.PackAndInspectCell",
      strategy: "one_for_one",
      meaning: "Pack and inspect cell runtime",
      machines: [
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
      spec: %EtherCAT{
        transport: %Transport{
          mode: :udp,
          bind_ip: @default_bind_ip,
          simulator_ip: @default_simulator_ip,
          primary_interface: nil,
          secondary_interface: nil
        },
        timing: %Timing{
          scan_stable_ms: 20,
          scan_poll_ms: 10,
          frame_timeout_ms: 20
        },
        domains: [@default_domain],
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
          "driver" => "Ogol.Hardware.EtherCAT.Driver.EK1100",
          "target_state" => "op",
          "process_data_mode" => "none",
          "process_data_domain" => "",
          "health_poll_ms" => ""
        },
        %{
          "name" => "inputs",
          "driver" => "Ogol.Hardware.EtherCAT.Driver.EL1809",
          "target_state" => "op",
          "process_data_mode" => "all",
          "process_data_domain" => "main",
          "health_poll_ms" => ""
        },
        %{
          "name" => "outputs",
          "driver" => "Ogol.Hardware.EtherCAT.Driver.EL2809",
          "target_state" => "op",
          "process_data_mode" => "all",
          "process_data_domain" => "main",
          "health_poll_ms" => ""
        }
      ]
    }
  end
end
