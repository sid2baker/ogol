defmodule Ogol.Skill do
  @moduledoc """
  Public machine capability descriptor.

  Skills are the invokable part of a machine's public interface.
  """

  @type kind :: :request | :event

  @type t :: %__MODULE__{
          name: atom(),
          kind: kind(),
          summary: String.t() | nil,
          args: list(),
          returns: term(),
          visible?: boolean(),
          available?: boolean() | nil
        }

  @enforce_keys [:name, :kind]
  defstruct [
    :name,
    :kind,
    :summary,
    args: [],
    returns: nil,
    visible?: true,
    available?: nil
  ]
end
