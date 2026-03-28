defmodule Ogol.Studio.Build.Artifact do
  @moduledoc false

  @enforce_keys [:id, :module, :beam, :source_digest]
  defstruct [:id, :module, :beam, :source_digest, :beam_path, diagnostics: []]

  @type t :: %__MODULE__{
          id: term(),
          module: module(),
          beam: binary(),
          source_digest: String.t(),
          beam_path: String.t() | nil,
          diagnostics: [term()]
        }
end
