defmodule Ogol.HMI.SurfaceCatalog do
  @moduledoc false

  alias Ogol.HMI.Surface
  alias Ogol.HMI.SurfaceDraftStore
  alias Ogol.HMI.Surfaces.OperationsAlarmFocus
  alias Ogol.HMI.Surfaces.OperationsOverview
  alias Ogol.HMI.Surfaces.OperationsStation

  @surface_modules [OperationsOverview, OperationsAlarmFocus, OperationsStation]

  def modules, do: @surface_modules

  def list_runtimes do
    Enum.map(@surface_modules, fn module ->
      surface_id = module |> Surface.runtime() |> Map.fetch!(:id)

      case fetch_resolved(surface_id) do
        {:ok, %{runtime: runtime}} -> runtime
        :error -> Surface.runtime(module)
      end
    end)
  end

  def fetch_runtime(surface_id) do
    case fetch_resolved(surface_id) do
      {:ok, %{runtime: runtime}} -> {:ok, runtime}
      :error -> :error
    end
  end

  def fetch_module(surface_id) do
    Enum.find(@surface_modules, fn module ->
      module
      |> Surface.runtime()
      |> then(&(to_string(&1.id) == to_string(surface_id)))
    end)
  end

  def fetch_resolved(surface_id, version \\ nil)

  def fetch_resolved(surface_id, version) do
    case SurfaceDraftStore.fetch_deployed_runtime(surface_id, version) do
      {:ok, runtime, version} ->
        {:ok, %{runtime: runtime, version: version, module: fetch_module(surface_id)}}

      :error ->
        fetch_module(surface_id)
        |> case do
          nil -> :error
          module -> {:ok, %{runtime: Surface.runtime(module), version: "current", module: module}}
        end
    end
  end
end
