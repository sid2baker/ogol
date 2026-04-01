defmodule Ogol.HMI.Surface.DeploymentStore do
  @moduledoc false

  use GenServer

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.Catalog, as: SurfaceCatalog
  alias Ogol.HMI.Surface.Deployments, as: SurfaceDeployment
  alias Ogol.HMI.Surface.Deployment

  @table :ogol_hmi_surface_deployments

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    :ets.delete_all_objects(@table)
    seed_defaults()
  end

  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.panel_id)
  end

  def default_assignment do
    SurfaceDeployment.default_panel()
    |> fetch_panel()
  end

  def fetch_panel(panel_id) do
    case :ets.lookup(@table, panel_id) do
      [{^panel_id, %Deployment{} = deployment}] -> deployment
      [] -> nil
    end
  end

  def fetch_surface_assignment(surface_id) do
    list()
    |> Enum.find(&(to_string(&1.surface_id) == to_string(surface_id)))
  end

  def assign_panel(panel_id, surface_id, opts \\ []) do
    panel_id = normalize_atom(panel_id)
    version = normalize_version(Keyword.get(opts, :version))

    assignment =
      fetch_panel(panel_id) || raise ArgumentError, "unknown panel #{inspect(panel_id)}"

    with {:ok, %{runtime: runtime, version: version, module: module}} <-
           SurfaceCatalog.fetch_resolved(surface_id, version) do
      updated =
        %Deployment{
          assignment
          | surface_id: runtime.id,
            surface_module: module || assignment.surface_module,
            surface_version: version,
            default_screen: runtime.default_screen
        }
        |> Surface.validate_deployment!(runtime)

      :ets.insert(@table, {panel_id, updated})
      updated
    else
      :error ->
        raise ArgumentError,
              "unknown surface/version #{inspect(surface_id)}#{if(version, do: "@#{version}", else: "")}"
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    seed_defaults()
    {:ok, %{}}
  end

  defp seed_defaults do
    Enum.each(SurfaceDeployment.defaults(), fn %Deployment{} = assignment ->
      runtime =
        case SurfaceCatalog.fetch_resolved(assignment.surface_id) do
          {:ok, %{runtime: runtime, version: version, module: module}} ->
            %{
              runtime: runtime,
              version: version,
              module: module || assignment.surface_module
            }

          :error ->
            %{
              runtime: Surface.runtime(assignment.surface_module),
              version: assignment.surface_version,
              module: assignment.surface_module
            }
        end

      seeded =
        %Deployment{
          assignment
          | surface_module: runtime.module,
            surface_version: runtime.version
        }
        |> Surface.validate_deployment!(runtime.runtime)

      :ets.insert(@table, {seeded.panel_id, seeded})
    end)

    :ok
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) do
    try do
      String.to_existing_atom(to_string(value))
    rescue
      ArgumentError -> raise ArgumentError, "unknown panel #{inspect(value)}"
    end
  end

  defp normalize_version(nil), do: nil
  defp normalize_version(""), do: nil
  defp normalize_version(value), do: to_string(value)
end
