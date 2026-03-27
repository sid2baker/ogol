defmodule Ogol.HMI.Surfaces.OperationsAlarmFocus do
  use Ogol.HMI.Surface

  surface id: :operations_alarm_focus,
          role: :overview,
          template: :overview,
          title: "Alarm Focus",
          summary:
            "Alarm-first runtime surface with compact status tiles, focused machine summaries, and visible issue detail.",
          default_screen: :overview do
    bindings do
      ref(:runtime_summary, :runtime_summary)
      ref(:alarm_summary, :alarm_summary)
      ref(:attention_lane, :attention_lane)
      ref(:machine_registry, :machine_registry)
      ref(:event_stream, :event_stream)
      ref(:ops_links, :ops_links)
    end

    screen :overview, title: "Alarm Focus" do
      variant :alarm_focus_wide do
        profile(:panel_1920x1080)
        grid(columns: 12, rows: 8, gap: :md)

        zone(:status_rail,
          area: {1, 1, 8, 2},
          node:
            group(:row,
              widgets: [
                widget(:status_tile,
                  binding: :runtime_summary,
                  label: "Healthy Units",
                  field: :active
                ),
                widget(:status_tile,
                  binding: :alarm_summary,
                  label: "Active Alarms",
                  field: :alarms
                ),
                widget(:status_tile, binding: :alarm_summary, label: "Faults", field: :faults)
              ]
            )
        )

        zone(:alarm_strip,
          area: {9, 1, 4, 2},
          node: widget(:fault_list, binding: :alarm_summary, limit: 4)
        )

        zone(:primary_action_area,
          area: {1, 3, 8, 2},
          node: widget(:attention_lane, binding: :attention_lane)
        )

        zone(:machine_tiles,
          area: {1, 5, 8, 4},
          node:
            group(:compact_grid,
              widgets: [
                widget(:machine_summary_card, binding: :machine_registry, index: 0),
                widget(:machine_summary_card, binding: :machine_registry, index: 1),
                widget(:machine_summary_card, binding: :machine_registry, index: 2),
                widget(:machine_summary_card, binding: :machine_registry, index: 3)
              ]
            )
        )

        zone(:detail_pane,
          area: {9, 3, 4, 4},
          node:
            widget(:value_grid,
              binding: :runtime_summary,
              fields: [:active, :faulted, :offline, :alarms]
            )
        )

        zone(:navigation_dock,
          area: {9, 7, 4, 2},
          node: widget(:quick_links, binding: :ops_links)
        )
      end

      variant :alarm_focus_compact do
        profile(:panel_1280x800)
        grid(columns: 12, rows: 8, gap: :md)

        zone(:status_rail,
          area: {1, 1, 12, 1},
          node:
            group(:compact_grid,
              widgets: [
                widget(:status_tile,
                  binding: :runtime_summary,
                  label: "Healthy Units",
                  field: :active
                ),
                widget(:status_tile,
                  binding: :alarm_summary,
                  label: "Active Alarms",
                  field: :alarms
                ),
                widget(:status_tile, binding: :alarm_summary, label: "Faults", field: :faults),
                widget(:status_tile, binding: :runtime_summary, label: "Offline", field: :offline)
              ]
            )
        )

        zone(:alarm_strip,
          area: {1, 2, 12, 1},
          node: widget(:fault_list, binding: :alarm_summary, limit: 3)
        )

        zone(:primary_action_area,
          area: {1, 3, 12, 2},
          node: widget(:attention_lane, binding: :attention_lane)
        )

        zone(:machine_tiles,
          area: {1, 5, 8, 4},
          node:
            group(:column,
              widgets: [
                widget(:machine_summary_card, binding: :machine_registry, index: 0),
                widget(:machine_summary_card, binding: :machine_registry, index: 1)
              ]
            )
        )

        zone(:detail_pane,
          area: {9, 5, 4, 3},
          node:
            widget(:value_grid,
              binding: :runtime_summary,
              fields: [:active, :faulted, :offline, :alarms]
            )
        )

        zone(:navigation_dock,
          area: {9, 8, 4, 1},
          node: widget(:quick_links, binding: :ops_links)
        )
      end
    end
  end
end
