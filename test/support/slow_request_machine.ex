defmodule Ogol.TestSupport.SlowRequestMachine do
  use Ogol.Machine

  boundary do
    request(:start)
    signal(:started)
  end

  states do
    state :idle do
      initial?(true)
    end

    state(:running)
  end

  transitions do
    transition :idle, :running do
      on({:request, :start})
      callback(:delayed_start)
      reply(:ok)
    end
  end

  def delayed_start(_delivered, _data, staging) do
    Process.sleep(150)

    {:ok,
     %{
       staging
       | boundary_effects:
           staging.boundary_effects ++
             [{:signal, %{name: :started, data: %{}, meta: %{via: :slow_request}}}]
     }}
  end
end
