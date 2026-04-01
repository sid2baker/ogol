defmodule Ogol.Machine.Studio.Model do
  @moduledoc false

  defmodule BoundaryDecl do
    @moduledoc false

    defstruct [:kind, :name, :type, :default, :meaning, :skill?, :public?, :provenance]
  end

  defmodule FieldDecl do
    @moduledoc false

    defstruct [:name, :type, :default, :meaning, :public?, :provenance]
  end

  defmodule StateNode do
    @moduledoc false

    defstruct [:name, :initial?, :status, :meaning, :provenance, entries: []]
  end

  defmodule TransitionEdge do
    @moduledoc false

    defstruct [
      :source,
      :destination,
      :trigger,
      :guard,
      :priority,
      :reenter?,
      :meaning,
      :provenance,
      actions: []
    ]
  end

  defmodule ActionNode do
    @moduledoc false

    defstruct [:kind, :args, :provenance]
  end

  defstruct [
    :module,
    :source_path,
    :compatibility,
    metadata: %{
      name: nil,
      meaning: nil,
      hardware_ref: nil,
      hardware_adapter: nil
    },
    boundary: %{
      facts: %{},
      events: %{},
      requests: %{},
      commands: %{},
      outputs: %{},
      signals: %{}
    },
    memory: %{fields: %{}},
    states: %{nodes: %{}, initial_state: nil},
    transitions: [],
    safety: [],
    children: [],
    provenance_index: %{}
  ]
end
