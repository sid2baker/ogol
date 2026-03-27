defmodule Ogol.Status do
  @moduledoc """
  Public runtime status projection for a machine.

  Status is the readable part of a machine's public interface.
  """

  alias Ogol.Interface

  @type health ::
          :healthy
          | :running
          | :waiting
          | :stopped
          | :faulted
          | :crashed
          | :recovering
          | :stale
          | :disconnected

  @type t :: %__MODULE__{
          machine_id: atom(),
          module: module() | nil,
          current_state: atom() | nil,
          health: health(),
          connected?: boolean(),
          facts: map(),
          outputs: map(),
          fields: map(),
          last_signal: atom() | nil,
          last_transition_at: integer() | nil
        }

  @enforce_keys [:machine_id, :health]
  defstruct [
    :machine_id,
    :module,
    :current_state,
    :health,
    connected?: false,
    facts: %{},
    outputs: %{},
    fields: %{},
    last_signal: nil,
    last_transition_at: nil
  ]

  @doc false
  @spec public_values(Interface.t(), map(), map(), map()) :: map()
  def public_values(%Interface{} = interface, facts, outputs, fields) do
    Map.merge(
      pick_public_values(facts, interface.status_spec.facts),
      Map.merge(
        pick_public_values(outputs, interface.status_spec.outputs),
        pick_public_values(fields, interface.status_spec.fields)
      )
    )
  end

  defp pick_public_values(values, _spec_items) when values == %{}, do: %{}

  defp pick_public_values(values, spec_items) when is_map(values) do
    spec_items
    |> Enum.flat_map(fn %{name: name} ->
      case Map.fetch(values, name) do
        {:ok, value} -> [{name, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end
end
