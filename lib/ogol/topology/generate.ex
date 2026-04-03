defmodule Ogol.Topology.Generate do
  @moduledoc false

  defmacro inject do
    quote generated: true do
      @ogol_topology Ogol.Topology.Normalize.from_dsl!(@spark_dsl_config, __MODULE__)

      def __ogol_topology__, do: @ogol_topology

      def start_link(opts \\ []) do
        Ogol.Topology.Runtime.start_link(@ogol_topology, opts)
      end

      def start(opts \\ []) do
        Ogol.Topology.Runtime.start(@ogol_topology, opts)
      end

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      def machine_pid(server, machine_name) do
        Ogol.Topology.Runtime.machine_pid(server, machine_name)
      end
    end
  end
end
