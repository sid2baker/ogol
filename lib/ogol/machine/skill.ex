defmodule Ogol.Machine.Skill do
  @moduledoc """
  Public machine capability descriptor.

  Skills are the invokable part of a machine's public interface.
  """

  @type kind :: :request | :event
  @type arg_type :: :string | :integer | :float | :boolean | {:enum, [String.t()]}

  @type arg_t :: %{
          required(:name) => atom(),
          required(:type) => arg_type(),
          optional(:summary) => String.t() | nil,
          optional(:default) => term()
        }

  @type t :: %__MODULE__{
          name: atom(),
          kind: kind(),
          summary: String.t() | nil,
          args: [arg_t()],
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
