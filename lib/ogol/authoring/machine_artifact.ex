defmodule Ogol.Authoring.MachineArtifact do
  @moduledoc false

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          source: String.t(),
          ast: Macro.t() | nil,
          module: module() | nil,
          uses_ogol_machine?: boolean() | nil,
          compatibility: :fully_editable | :partially_representable | :not_visually_editable,
          diagnostics: [Ogol.Authoring.MachineDiagnostic.t()],
          sections: map()
        }

  defstruct [
    :path,
    :source,
    :ast,
    :module,
    :uses_ogol_machine?,
    :compatibility,
    diagnostics: [],
    sections: %{}
  ]
end
