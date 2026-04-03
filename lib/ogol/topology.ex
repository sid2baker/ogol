defmodule Ogol.Topology do
  @moduledoc """
  Spark-backed authoring entrypoint for explicit Ogol topologies.

  Topology modules own deployment, supervision, and machine instance naming.
  Cross-machine orchestration lives in sequences, not in machine topology wiring.
  """

  use Spark.Dsl,
    default_extensions: [
      extensions: [Ogol.Topology.Dsl]
    ]

  @spec scope(module()) :: atom()
  def scope(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  @spec scope_name(module() | String.t()) :: String.t()
  def scope_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  def scope_name(module_name) when is_binary(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end

  def handle_before_compile(_opts) do
    quote generated: true do
      require Ogol.Topology.Generate
      Ogol.Topology.Generate.inject()
    end
  end
end
