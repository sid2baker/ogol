defmodule Ogol.HMI.SurfaceDefinitionTest do
  use ExUnit.Case, async: false

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.Catalog, as: SurfaceCatalog
  alias Ogol.HMI.Surface.Deployments, as: SurfaceDeployment
  alias Ogol.HMI.Surface.DeploymentStore, as: SurfaceDeploymentStore
  alias Ogol.HMI.Surface.DeviceProfiles
  alias Ogol.HMI.Surface.RuntimeStore, as: SurfaceRuntimeStore

  alias Ogol.HMI.Surface.Builtins.OperationsOverview
  alias Ogol.HMI.Surface.Builtins.OperationsStation

  setup do
    SurfaceRuntimeStore.reset()
    SurfaceDeploymentStore.reset()
    :ok
  end

  test "compiles the default runtime overview surface" do
    definition = Surface.definition(OperationsOverview)
    runtime = Surface.runtime(OperationsOverview)

    assert definition.id == :operations_overview
    assert definition.role == :overview
    assert definition.template == :overview
    assert runtime.default_screen == :overview

    assert runtime.bindings |> Map.keys() |> Enum.sort() == [
             :alarm_summary,
             :attention_lane,
             :event_stream,
             :machine_registry,
             :ops_links,
             :runtime_summary
           ]

    screen = Surface.find_screen(runtime, :overview)
    assert screen.variants |> Map.keys() |> Enum.sort() == [:panel_1280x800, :panel_1920x1080]

    wide_variant = Surface.select_variant(screen, :panel_1920x1080)
    compact_variant = Surface.select_variant(screen, :panel_1280x800)

    assert wide_variant.grid.columns == 12
    assert wide_variant.grid.rows == 8
    assert compact_variant.grid.columns == 12
    assert compact_variant.grid.rows == 8

    zone_ids = Map.keys(wide_variant.zones)

    assert :status_rail in zone_ids
    assert :alarm_strip in zone_ids
    assert :primary_action_area in zone_ids
    assert :machine_tiles in zone_ids
    assert :detail_pane in zone_ids
    assert :navigation_dock in zone_ids
  end

  test "compiles the station runtime surface" do
    definition = Surface.definition(OperationsStation)
    runtime = Surface.runtime(OperationsStation)

    assert definition.id == :operations_station
    assert definition.role == :station
    assert definition.template == :station
    assert runtime.default_screen == :station

    assert runtime.bindings |> Map.keys() |> Enum.sort() == [
             :station_alarm_summary,
             :station_events,
             :station_links,
             :station_skills,
             :station_status,
             :station_summary
           ]

    screen = Surface.find_screen(runtime, :station)
    assert screen.variants |> Map.keys() |> Enum.sort() == [:panel_1280x800, :panel_1920x1080]

    wide_variant = Surface.select_variant(screen, :panel_1920x1080)

    assert Map.keys(wide_variant.zones) |> Enum.sort() == [
             :alarm_strip,
             :detail_pane,
             :navigation_dock,
             :primary_action_area,
             :status_rail
           ]
  end

  test "catalog and deployment expose the assigned runtime surface" do
    {:ok, runtime} = SurfaceCatalog.fetch_runtime(:operations_overview)
    assignment = SurfaceDeployment.default_assignment()

    assert runtime.id == :operations_overview
    assert assignment.surface_id == :operations_overview
    assert assignment.default_screen == :overview
    assert assignment.viewport_profile == :panel_1920x1080
    assert DeviceProfiles.fetch(assignment.viewport_profile).width == 1920

    assert Surface.select_variant(
             Surface.find_screen(runtime, :overview),
             assignment.viewport_profile
           )
  end

  test "surface validation rejects overlapping zones" do
    assert_raise ArgumentError, ~r/overlap/, fn ->
      compile_surface("""
      defmodule TestOverlapSurface do
        use Ogol.HMI.Surface

        surface id: :test_overlap, role: :overview, template: :overview, title: "Overlap", summary: "Overlap", default_screen: :overview do
          bindings do
            ref(:runtime_summary, :runtime_summary)
            ref(:alarm_summary, :alarm_summary)
            ref(:attention_lane, :attention_lane)
            ref(:machine_registry, :machine_registry)
            ref(:event_stream, :event_stream)
            ref(:ops_links, :ops_links)
          end

          screen :overview do
            variant :wide do
              profile(:panel_1920x1080)
              grid(columns: 12, rows: 8, gap: :md)

              zone :status_rail, area: {1, 1, 12, 2}, node: widget(:summary_strip, binding: :runtime_summary)
              zone :alarm_strip, area: {1, 2, 12, 2}, node: widget(:alarm_strip, binding: :alarm_summary)
              zone :primary_action_area, area: {1, 4, 12, 1}, node: widget(:attention_lane, binding: :attention_lane)
              zone :machine_tiles, area: {1, 5, 8, 4}, node: widget(:machine_grid, binding: :machine_registry)
              zone :detail_pane, area: {9, 5, 4, 3}, node: widget(:event_ticker, binding: :event_stream)
              zone :navigation_dock, area: {9, 8, 4, 1}, node: widget(:quick_links, binding: :ops_links)
            end
          end
        end
      end
      """)
    end
  end

  test "surface validation rejects unknown widget types" do
    assert_raise ArgumentError, ~r/unknown widget/, fn ->
      compile_surface("""
      defmodule TestUnknownWidgetSurface do
        use Ogol.HMI.Surface

        surface id: :test_unknown_widget, role: :overview, template: :overview, title: "Unknown", summary: "Unknown", default_screen: :overview do
          bindings do
            ref(:runtime_summary, :runtime_summary)
            ref(:alarm_summary, :alarm_summary)
            ref(:attention_lane, :attention_lane)
            ref(:machine_registry, :machine_registry)
            ref(:event_stream, :event_stream)
            ref(:ops_links, :ops_links)
          end

          screen :overview do
            variant :wide do
              profile(:panel_1920x1080)
              grid(columns: 12, rows: 8, gap: :md)

              zone :status_rail, area: {1, 1, 12, 1}, node: widget(:bogus_widget, binding: :runtime_summary)
              zone :alarm_strip, area: {1, 2, 12, 1}, node: widget(:alarm_strip, binding: :alarm_summary)
              zone :primary_action_area, area: {1, 3, 12, 2}, node: widget(:attention_lane, binding: :attention_lane)
              zone :machine_tiles, area: {1, 5, 8, 4}, node: widget(:machine_grid, binding: :machine_registry)
              zone :detail_pane, area: {9, 5, 4, 3}, node: widget(:event_ticker, binding: :event_stream)
              zone :navigation_dock, area: {9, 8, 4, 1}, node: widget(:quick_links, binding: :ops_links)
            end
          end
        end
      end
      """)
    end
  end

  defp compile_surface(source) do
    unique = System.unique_integer([:positive])
    source = String.replace(source, "TestOverlapSurface", "TestOverlapSurface#{unique}")

    source =
      String.replace(source, "TestUnknownWidgetSurface", "TestUnknownWidgetSurface#{unique}")

    Code.compile_string(source)
  end
end
