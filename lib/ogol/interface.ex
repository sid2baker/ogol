defmodule Ogol.Interface do
  @moduledoc false

  @type signal :: %{name: atom(), summary: String.t() | nil}

  @type t :: %__MODULE__{
          machine_id: atom(),
          module: module(),
          summary: String.t() | nil,
          skills: [Ogol.Machine.Skill.t()],
          signals: [signal()],
          status_spec: Ogol.StatusSpec.t()
        }

  @enforce_keys [:machine_id, :module]
  defstruct [
    :machine_id,
    :module,
    :summary,
    skills: [],
    signals: [],
    status_spec: %Ogol.StatusSpec{}
  ]
end
