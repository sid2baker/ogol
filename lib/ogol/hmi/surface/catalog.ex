defmodule Ogol.HMI.Surface.Catalog do
  @moduledoc false

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.Builtins.OperationsAlarmFocus
  alias Ogol.HMI.Surface.Builtins.OperationsOverview
  alias Ogol.HMI.Surface.Builtins.OperationsStation
  alias Ogol.HMI.Surface.RuntimeStore, as: SurfaceRuntimeStore

  @surface_modules [OperationsOverview, OperationsAlarmFocus, OperationsStation]

  def modules, do: @surface_modules

  def list_runtimes do
    builtins_by_id =
      Map.new(@surface_modules, fn module ->
        runtime = Surface.runtime(module)
        {to_string(runtime.id), runtime}
      end)

    deployed_runtimes =
      SurfaceRuntimeStore.list_entries()
      |> Enum.reduce([], fn entry, runtimes ->
        case SurfaceRuntimeStore.fetch_deployed(entry.surface_id) do
          {:ok, %{runtime: runtime}} -> [runtime | runtimes]
          :error -> runtimes
        end
      end)
      |> Enum.reverse()

    deployed_ids = MapSet.new(Enum.map(deployed_runtimes, &to_string(&1.id)))

    builtins =
      builtins_by_id
      |> Enum.reject(fn {surface_id, _runtime} -> MapSet.member?(deployed_ids, surface_id) end)
      |> Enum.map(fn {_surface_id, runtime} -> runtime end)

    deployed_runtimes ++ builtins
  end

  def fetch_runtime(surface_id) do
    case fetch_resolved(surface_id) do
      {:ok, %{runtime: runtime}} -> {:ok, runtime}
      :error -> :error
    end
  end

  def fetch_module(surface_id) do
    fetch_builtin_module(surface_id)
  end

  def fetch_resolved(surface_id, version \\ nil)

  def fetch_resolved(surface_id, version) do
    case SurfaceRuntimeStore.fetch_deployed(surface_id, version) do
      {:ok, resolved} ->
        {:ok, resolved}

      :error ->
        fetch_builtin_module(surface_id)
        |> case do
          nil -> :error
          module -> {:ok, %{runtime: Surface.runtime(module), version: "current", module: module}}
        end
    end
  end

  defp fetch_builtin_module(surface_id) do
    Enum.find(@surface_modules, fn module ->
      module
      |> Surface.runtime()
      |> then(&(to_string(&1.id) == to_string(surface_id)))
    end)
  end
end
