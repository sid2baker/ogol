defmodule Ogol.Session.ArtifactRuntime do
  @moduledoc false

  @type kind :: :hardware | :machine | :sequence | :topology
  @type key :: {kind(), String.t()}

  @type t :: %__MODULE__{
          id: key(),
          kind: kind(),
          artifact_id: String.t(),
          module: module() | nil,
          source_digest: String.t() | nil,
          blocked_reason: term() | nil,
          lingering_pids: [pid()],
          diagnostics: [String.t()]
        }

  defstruct [
    :id,
    :kind,
    :artifact_id,
    :module,
    :source_digest,
    blocked_reason: nil,
    lingering_pids: [],
    diagnostics: []
  ]

  @spec from_status(map()) :: t()
  def from_status(
        %{
          id: {kind, artifact_id} = id,
          kind: kind,
          artifact_id: artifact_id
        } = status
      )
      when kind in [:hardware, :machine, :sequence, :topology] and
             is_binary(artifact_id) do
    %__MODULE__{
      id: id,
      kind: kind,
      artifact_id: artifact_id,
      module: Map.get(status, :module),
      source_digest: Map.get(status, :source_digest),
      blocked_reason: Map.get(status, :blocked_reason),
      lingering_pids: List.wrap(Map.get(status, :lingering_pids, [])),
      diagnostics: List.wrap(Map.get(status, :diagnostics, []))
    }
  end
end
