defmodule Ogol.HMI.Surface.Builtins.OperationsOverview do
  use Ogol.HMI.Surface

  surface id: :operations_overview,
          role: :overview,
          template: :overview,
          title: "Operations Triage",
          summary:
            "Assigned runtime surface for high-contrast line triage, alarm visibility, and safe operator actions.",
          default_screen: :procedures do
    bindings do
      ref(:runtime_summary, :runtime_summary)
      ref(:alarm_summary, :alarm_summary)
      ref(:orchestration_status, :orchestration_status)
      ref(:procedure_catalog, :procedure_catalog)
      ref(:machine_registry, :machine_registry)
      ref(:event_stream, :event_stream)
      ref(:ops_links, :ops_links)
    end

    screen :procedures, title: "Procedures" do
      variant :procedures_wide do
        profile(:panel_1920x1080)
        grid(columns: 12, rows: 8, gap: :md)

        zone(:status_rail,
          area: {1, 1, 8, 1},
          node:
            group(:row,
              widgets: [
                widget(:status_tile,
                  binding: :orchestration_status,
                  label: "Mode",
                  field: :control_mode
                ),
                widget(:status_tile,
                  binding: :orchestration_status,
                  label: "Owner",
                  field: :owner_kind
                ),
                widget(:status_tile,
                  binding: :orchestration_status,
                  label: "Trust",
                  field: :runtime_trust_state
                ),
                widget(:status_tile,
                  binding: :orchestration_status,
                  label: "Policy",
                  field: :run_policy
                )
              ]
            )
        )

        zone(:alarm_strip,
          area: {9, 1, 4, 1},
          node:
            group(:row,
              widgets: [
                widget(:status_tile, binding: :alarm_summary, label: "Alarms", field: :alarms),
                widget(:status_tile, binding: :alarm_summary, label: "Faults", field: :faults)
              ]
            )
        )

        zone(:primary_action_area,
          area: {1, 2, 12, 5},
          node: widget(:procedure_panel, binding: :orchestration_status)
        )

        zone(:machine_tiles,
          area: {1, 7, 5, 2},
          node:
            group(:row,
              widgets: [
                widget(:machine_summary_card, binding: :machine_registry, index: 0),
                widget(:machine_summary_card, binding: :machine_registry, index: 1)
              ]
            )
        )

        zone(:detail_pane,
          area: {6, 7, 4, 2},
          node:
            widget(:value_grid,
              binding: :runtime_summary,
              fields: [:active, :faulted, :offline, :alarms]
            )
        )

        zone(:navigation_dock,
          area: {10, 7, 3, 2},
          node: widget(:quick_links, binding: :ops_links)
        )
      end

      variant :procedures_compact do
        profile(:panel_1280x800)
        grid(columns: 12, rows: 8, gap: :md)

        zone(:status_rail,
          area: {1, 1, 6, 1},
          node:
            group(:row,
              widgets: [
                widget(:status_tile,
                  binding: :orchestration_status,
                  label: "Mode",
                  field: :control_mode
                ),
                widget(:status_tile,
                  binding: :orchestration_status,
                  label: "Owner",
                  field: :owner_kind
                )
              ]
            )
        )

        zone(:alarm_strip,
          area: {7, 1, 6, 1},
          node:
            group(:row,
              widgets: [
                widget(:status_tile, binding: :alarm_summary, label: "Alarms", field: :alarms),
                widget(:status_tile, binding: :alarm_summary, label: "Faults", field: :faults)
              ]
            )
        )

        zone(:primary_action_area,
          area: {1, 2, 12, 5},
          node: widget(:procedure_panel, binding: :orchestration_status)
        )

        zone(:machine_tiles,
          area: {1, 7, 6, 1},
          node:
            group(:row,
              widgets: [
                widget(:machine_summary_card, binding: :machine_registry, index: 0),
                widget(:machine_summary_card, binding: :machine_registry, index: 1)
              ]
            )
        )

        zone(:detail_pane,
          area: {7, 7, 6, 1},
          node: widget(:value_grid, binding: :runtime_summary, fields: [:active, :faulted])
        )

        zone(:navigation_dock,
          area: {1, 8, 12, 1},
          node: widget(:quick_links, binding: :ops_links)
        )
      end
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
          node: widget(:procedure_panel, binding: :orchestration_status)
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
          node: widget(:procedure_panel, binding: :orchestration_status)
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
