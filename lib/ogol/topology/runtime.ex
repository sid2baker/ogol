defmodule Ogol.Topology.Runtime do
  @moduledoc false

  use GenServer

  alias Ogol.Topology.Model

  defstruct [:root_name, :router, :supervisor]

  def start_link(%Model{} = topology, opts \\ []) do
    GenServer.start_link(__MODULE__, {topology, opts}, name: Keyword.get(opts, :name))
  end

  def start(%Model{} = topology, opts \\ []) do
    GenServer.start(__MODULE__, {topology, opts}, name: Keyword.get(opts, :name))
  end

  def machine_pid(topology, name) when is_pid(topology) and is_atom(name) do
    GenServer.call(topology, {:machine_pid, name})
  end

  def brain_pid(topology) when is_pid(topology) do
    GenServer.call(topology, :brain_pid)
  end

  @impl true
  def init({%Model{} = topology, opts}) do
    with :ok <-
           Ogol.Topology.Registry.claim_topology(%{
             module: topology.module,
             root: topology.root
           }),
         {:ok, router} <-
           Ogol.Topology.Router.start_link(
             root_machine_id: topology.root,
             observations: topology.observations
           ),
         {:ok, supervisor} <-
           Supervisor.start_link(build_machine_specs(topology, router, opts),
             strategy: topology.strategy
           ),
         :ok <- Ogol.Topology.Router.await_ready(router) do
      root_pid = Ogol.Topology.Router.root_pid(router)

      Ogol.HMI.RuntimeNotifier.emit(:topology_ready,
        machine_id: topology.root,
        topology_id: topology.root,
        source: __MODULE__,
        payload: %{root_machine_id: topology.root},
        meta: %{pid: self(), root_pid: root_pid, supervisor: supervisor}
      )

      {:ok, %__MODULE__{root_name: topology.root, router: router, supervisor: supervisor}}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:machine_pid, name}, _from, state) do
    {:reply, Ogol.Topology.Registry.whereis(name), state}
  end

  def handle_call(:brain_pid, _from, state) do
    {:reply, Ogol.Topology.Registry.whereis(state.root_name), state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_if_alive(state.supervisor)
    stop_if_alive(state.router)
    :ok
  end

  defp build_machine_specs(%Model{} = topology, router, opts) do
    root_signal_sink = Keyword.get(opts, :signal_sink)
    machine_overrides = Keyword.get(opts, :machine_opts, %{})

    Enum.map(topology.machines, fn spec ->
      override_opts = Map.get(machine_overrides, spec.name, [])

      machine_opts =
        spec
        |> Map.get(:opts, [])
        |> Keyword.merge(override_opts)
        |> Keyword.put(:machine_id, spec.name)
        |> Keyword.put(:name, Ogol.Topology.Registry.via(spec.name))
        |> Keyword.put(
          :signal_sink,
          signal_sink_for(spec.name, topology.root, root_signal_sink, router)
        )
        |> Keyword.put(:topology_router, router)

      Supervisor.child_spec({spec.module, machine_opts},
        id: {:ogol_machine, spec.name},
        restart: Map.get(spec, :restart, :permanent)
      )
    end)
  end

  defp signal_sink_for(machine_name, root_name, root_signal_sink, _router)
       when machine_name == root_name,
       do: root_signal_sink

  defp signal_sink_for(_machine_name, _root_name, _root_signal_sink, router), do: router

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp stop_if_alive(_pid), do: :ok
end
