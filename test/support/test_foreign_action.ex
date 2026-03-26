defmodule Ogol.TestSupport.TestForeignAction do
  @behaviour Ogol.ForeignAction

  @impl true
  def run(:mark_and_signal, opts, _machine_module, _delivered, staging) do
    field = Keyword.fetch!(opts, :field)
    signal = Keyword.fetch!(opts, :signal)

    next_data = %{staging.data | fields: Map.put(staging.data.fields, field, :foreign)}

    {:ok,
     %{
       staging
       | data: next_data,
         boundary_effects:
           staging.boundary_effects ++
             [{:signal, %{name: signal, data: %{}, meta: %{via: :foreign}}}]
     }}
  end
end
