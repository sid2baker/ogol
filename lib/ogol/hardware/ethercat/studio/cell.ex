defmodule Ogol.Hardware.EtherCAT.Studio.Cell do
  @moduledoc false

  @behaviour Ogol.Studio.Cell

  alias Ogol.Hardware.Studio.Cell, as: HardwareCell
  alias Ogol.Studio.Cell.Derived
  alias Ogol.Studio.Cell.Facts

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns),
    do: HardwareCell.facts_from_assigns(assigns)

  @impl true
  @spec derive(Facts.t()) :: Derived.t()
  def derive(%Facts{} = facts) do
    %Derived{HardwareCell.derive(facts) | views: []}
  end

  @spec default_runtime_status() :: map()
  def default_runtime_status, do: HardwareCell.default_runtime_status()
end
