defmodule Ogol.Hardware.EtherCAT.Ref do
  @moduledoc """
  Endpoint-first machine binding for one configured EtherCAT slave.

  EtherCAT drivers and slave aliases now define the public endpoint names.
  Ogol keeps only the machine-to-slave subset selection here:

  - `:slave` - configured EtherCAT slave name
  - `:outputs` - machine outputs this slave should handle directly via matching endpoint names
  - `:facts` - machine facts this slave should update from matching endpoint names
  - `:commands` - optional explicit command bindings using endpoint-aware EtherCAT commands
  - `:event_name` - optional machine event name for forwarded public slave events
  - `:meta` - default metadata merged into outgoing and incoming EtherCAT events
  """

  @type command_binding :: {:command, atom(), map()}

  @type t :: %__MODULE__{
          slave: atom(),
          outputs: [atom()],
          facts: [atom()],
          commands: %{optional(atom()) => command_binding()},
          event_name: atom() | nil,
          meta: map()
        }

  @enforce_keys [:slave]
  defstruct slave: nil,
            outputs: [],
            facts: [],
            commands: %{},
            event_name: nil,
            meta: %{}

  @spec fact_endpoints(t()) :: [atom()]
  def fact_endpoints(%__MODULE__{} = ref) do
    ref.facts
    |> List.wrap()
    |> Enum.uniq()
  end

  @spec handles_output?(t(), atom()) :: boolean()
  def handles_output?(%__MODULE__{} = ref, output) when is_atom(output) do
    output in List.wrap(ref.outputs)
  end

  @spec handles_command?(t(), atom()) :: boolean()
  def handles_command?(%__MODULE__{} = ref, command) when is_atom(command) do
    Map.has_key?(ref.commands, command)
  end

  @spec observes_fact?(t(), atom()) :: boolean()
  def observes_fact?(%__MODULE__{} = ref, fact) when is_atom(fact) do
    fact in fact_endpoints(ref)
  end

  @spec event_name(t()) :: atom() | nil
  def event_name(%__MODULE__{event_name: event_name}), do: event_name

  @spec observes_events?(t()) :: boolean()
  def observes_events?(%__MODULE__{} = ref),
    do: not is_nil(event_name(ref)) and is_atom(event_name(ref))

  @spec observes_anything?(t()) :: boolean()
  def observes_anything?(%__MODULE__{} = ref) do
    observes_events?(ref) or fact_endpoints(ref) != []
  end
end
