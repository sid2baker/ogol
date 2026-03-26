defmodule Ogol.Hardware.EtherCAT.Ref do
  @moduledoc """
  Configuration bundle for the EtherCAT adapter.

  Ogol keeps only the machine-to-fieldbus mapping here. The actual EtherCAT
  runtime and simulator live in the external `:ethercat` dependency.

  Fields:
  - `:mode` - `:runtime` or `:simulator`
  - `:slave` - named EtherCAT slave
  - `:command_map` - maps machine commands to EtherCAT operations
  - `:output_map` - maps machine outputs to EtherCAT signals
  - `:fact_map` - maps incoming EtherCAT signals back to machine facts
  - `:observe_signals` - additional EtherCAT signals that should emit hardware events
  - `:observe_events?` - whether public slave events should emit hardware events
  - `:hardware_event` - hardware event name emitted back into the machine
  - `:meta` - default metadata merged into outgoing and incoming EtherCAT events
  """

  @type t :: %__MODULE__{
          mode: :runtime | :simulator,
          slave: atom(),
          command_map: map(),
          output_map: map(),
          fact_map: %{optional(atom()) => atom()},
          observe_signals: [atom()],
          observe_events?: boolean(),
          hardware_event: atom(),
          meta: map()
        }

  @enforce_keys [:slave]
  defstruct mode: :runtime,
            slave: nil,
            command_map: %{},
            output_map: %{},
            fact_map: %{},
            observe_signals: [],
            observe_events?: false,
            hardware_event: :process_image,
            meta: %{}

  @spec observed_signals(t()) :: [atom()]
  def observed_signals(%__MODULE__{} = ref) do
    ref.fact_map
    |> Map.keys()
    |> Kernel.++(List.wrap(ref.observe_signals))
    |> Enum.uniq()
  end

  @spec observes_signal?(t(), atom()) :: boolean()
  def observes_signal?(%__MODULE__{} = ref, signal) when is_atom(signal) do
    signal in observed_signals(ref)
  end

  @spec observes_events?(t()) :: boolean()
  def observes_events?(%__MODULE__{observe_events?: value}), do: value == true

  @spec observes_anything?(t()) :: boolean()
  def observes_anything?(%__MODULE__{} = ref) do
    observes_events?(ref) or observed_signals(ref) != []
  end
end
