defmodule Ogol.HMI.Surface.Builtins.OperationsOverview do
  use Ogol.HMI.Surface

  surface id: :operations_overview,
          role: :overview,
          template: :overview,
          title: "Operations Triage",
          summary:
            "Assigned runtime surface for high-contrast line triage, alarm visibility, and safe operator actions.",
          default_screen: :overview do
    bindings do
      ref(:runtime_summary, :runtime_summary)
      ref(:alarm_summary, :alarm_summary)
      ref(:attention_lane, :attention_lane)
      ref(:machine_registry, :machine_registry)
      ref(:event_stream, :event_stream)
      ref(:ops_links, :ops_links)
    end

    screen :overview, title: "Overview" do
      variant :overview_wide do
        profile(:panel_1920x1080)
        grid(columns: 12, rows: 8, gap: :md)

        zone(:status_rail,
          area: {1, 1, 8, 2},
          node: widget(:summary_strip, binding: :runtime_summary)
        )

        zone(:alarm_strip,
          area: {9, 1, 4, 2},
          node: widget(:alarm_strip, binding: :alarm_summary)
        )

        zone(:primary_action_area,
          area: {1, 3, 8, 2},
          node: widget(:attention_lane, binding: :attention_lane)
        )

        zone(:machine_tiles,
          area: {1, 5, 8, 4},
          node: widget(:machine_grid, binding: :machine_registry)
        )

        zone(:detail_pane,
          area: {9, 3, 4, 4},
          node: widget(:event_ticker, binding: :event_stream)
        )

        zone(:navigation_dock,
          area: {9, 7, 4, 2},
          node: widget(:quick_links, binding: :ops_links)
        )
      end

      variant :overview_compact do
        profile(:panel_1280x800)
        grid(columns: 12, rows: 8, gap: :md)

        zone(:status_rail,
          area: {1, 1, 12, 1},
          node: widget(:summary_strip, binding: :runtime_summary)
        )

        zone(:alarm_strip,
          area: {1, 2, 12, 1},
          node: widget(:alarm_strip, binding: :alarm_summary)
        )

        zone(:primary_action_area,
          area: {1, 3, 12, 2},
          node: widget(:attention_lane, binding: :attention_lane)
        )

        zone(:machine_tiles,
          area: {1, 5, 8, 4},
          node: widget(:machine_grid, binding: :machine_registry)
        )

        zone(:detail_pane,
          area: {9, 5, 4, 3},
          node: widget(:event_ticker, binding: :event_stream)
        )

        zone(:navigation_dock,
          area: {9, 8, 4, 1},
          node: widget(:quick_links, binding: :ops_links)
        )
      end
    end
  end
end
