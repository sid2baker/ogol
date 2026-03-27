defmodule Ogol.HMI.Surfaces.OperationsStation do
  use Ogol.HMI.Surface

  surface id: :operations_station,
          role: :station,
          template: :station,
          title: "Station Panel",
          summary:
            "Focused operator surface for one machine with current state, local alarms, recent events, and safe station actions.",
          default_screen: :station do
    bindings do
      ref(:station_status, {:machine_status, :simple_hmi_line})
      ref(:station_alarm_summary, {:machine_alarm_summary, :simple_hmi_line})
      ref(:station_skills, {:machine_skills, :simple_hmi_line})
      ref(:station_summary, {:machine_summary, :simple_hmi_line})
      ref(:station_events, {:machine_events, :simple_hmi_line})

      ref(
        :station_links,
        {:static_links,
         [
           %{
             label: "Operations",
             detail: "Return to the assigned runtime entry surface.",
             path: "/ops",
             disabled: false
           },
           %{
             label: "Machine Detail",
             detail: "Open the focused machine drill-down view.",
             path: "/ops/machines/simple_hmi_line",
             disabled: false
           }
         ]}
      )
    end

    screen :station, title: "Station" do
      variant :station_wide do
        profile(:panel_1920x1080)
        grid(columns: 12, rows: 8, gap: :md)

        zone(:status_rail,
          area: {1, 1, 8, 2},
          node:
            group(:row,
              widgets: [
                widget(:status_tile,
                  binding: :station_status,
                  label: "State",
                  field: :current_state
                ),
                widget(:status_tile,
                  binding: :station_status,
                  label: "Running",
                  field: :running?
                ),
                widget(:status_tile,
                  binding: :station_status,
                  label: "Parts",
                  field: :part_count
                )
              ]
            )
        )

        zone(:alarm_strip,
          area: {9, 1, 4, 2},
          node: widget(:alarm_strip, binding: :station_alarm_summary)
        )

        zone(:primary_action_area,
          area: {1, 3, 4, 3},
          node:
            widget(:skill_button_group,
              binding: :station_skills,
              skills: [:start, :stop, :part_seen]
            )
        )

        zone(:detail_pane,
          area: {5, 3, 8, 4},
          node:
            group(:column,
              widgets: [
                widget(:machine_summary_card, binding: :station_summary),
                widget(:event_ticker, binding: :station_events)
              ]
            )
        )

        zone(:navigation_dock,
          area: {1, 6, 4, 2},
          node: widget(:quick_links, binding: :station_links)
        )
      end

      variant :station_compact do
        profile(:panel_1280x800)
        grid(columns: 12, rows: 8, gap: :md)

        zone(:status_rail,
          area: {1, 1, 12, 1},
          node:
            group(:compact_grid,
              widgets: [
                widget(:status_tile,
                  binding: :station_status,
                  label: "State",
                  field: :current_state
                ),
                widget(:status_tile,
                  binding: :station_status,
                  label: "Running",
                  field: :running?
                ),
                widget(:status_tile,
                  binding: :station_status,
                  label: "Parts",
                  field: :part_count
                )
              ]
            )
        )

        zone(:alarm_strip,
          area: {1, 2, 12, 1},
          node: widget(:alarm_strip, binding: :station_alarm_summary)
        )

        zone(:primary_action_area,
          area: {1, 3, 12, 2},
          node:
            widget(:skill_button_group,
              binding: :station_skills,
              skills: [:start, :stop, :part_seen]
            )
        )

        zone(:detail_pane,
          area: {1, 5, 12, 3},
          node:
            group(:column,
              widgets: [
                widget(:machine_summary_card, binding: :station_summary),
                widget(:event_ticker, binding: :station_events)
              ]
            )
        )

        zone(:navigation_dock,
          area: {1, 8, 12, 1},
          node: widget(:quick_links, binding: :station_links)
        )
      end
    end
  end
end
