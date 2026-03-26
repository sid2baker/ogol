defmodule Ogol.TestSupport.CallbackActionMachine do
  use Ogol.Machine

  boundary do
    request(:start)
    signal(:callback_ran)
  end

  memory do
    field(:count, :integer, default: 0)
  end

  states do
    state :idle do
      initial?(true)
    end
  end

  transitions do
    transition :idle, :idle do
      on({:request, :start})
      callback(:increment_and_signal)
      reply(:ok)
    end
  end

  def increment_and_signal(_delivered, _data, staging) do
    next_data = %{staging.data | fields: Map.put(staging.data.fields, :count, 1)}

    {:ok,
     %{
       staging
       | data: next_data,
         boundary_effects:
           staging.boundary_effects ++
             [{:signal, %{name: :callback_ran, data: %{}, meta: %{via: :callback}}}]
     }}
  end
end
