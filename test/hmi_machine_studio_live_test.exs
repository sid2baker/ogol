defmodule Ogol.HMI.MachineStudioLiveTest do
  use Ogol.ConnCase, async: false

  test "renders the machine library on the left and the selected studio cell in the middle" do
    {:ok, view, html} = live(build_conn(), "/studio/machines")

    assert html =~ "Machine Studio"
    assert html =~ "Machines"
    assert html =~ "Packaging Line coordinator"
    assert html =~ "Inspection cell coordinator"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert has_element?(view, "button", "Visual")
    assert has_element?(view, "button", "New")
  end

  test "switches to source mode in place for the selected machine" do
    {:ok, view, _html} = live(build_conn(), "/studio/machines")

    render_click(view, "set_editor_mode", %{"mode" => "source"})

    html = render(view)

    assert html =~ "defmodule Ogol.Generated.Machines.PackagingLine do"
    assert html =~ "use Ogol.Machine"
  end

  test "selects another machine from the library with route-driven navigation" do
    {:ok, _view, html} = live(build_conn(), "/studio/machines/inspection_cell")

    assert html =~ "Inspection cell coordinator"
    assert html =~ "Ogol.Generated.Machines.InspectionCell"
  end

  test "creates a new machine draft from the library" do
    {:ok, view, _html} = live(build_conn(), "/studio/machines")

    render_click(view, "new_machine", %{})

    assert_patch(view, "/studio/machines/machine_1")
    assert render(view) =~ "machine_1"
  end

  test "falls back to source mode when the machine source leaves the supported subset" do
    {:ok, view, _html} = live(build_conn(), "/studio/machines")

    unsupported_source = """
    defmodule Ogol.Generated.Machines.PackagingLine do
      use Ogol.Machine

      machine do
        name(:packaging_line)
      end

      memory do
        field(:retry_count, :integer, default: 0)
      end
    end
    """

    render_change(view, "change_source", %{"draft" => %{"source" => unsupported_source}})

    html = render(view)

    assert html =~ "Source only"
    assert html =~ "memory fields require source editing"
    assert html =~ "memory do"
  end

  test "visual edits update the selected machine draft" do
    {:ok, view, _html} = live(build_conn(), "/studio/machines")

    render_change(view, "change_visual", %{
      "machine" => %{
        "machine_id" => "packaging_line",
        "module_name" => "Ogol.Generated.Machines.PackagingLine",
        "meaning" => "Packaging line supervisor",
        "request_count" => "3",
        "event_count" => "1",
        "command_count" => "0",
        "signal_count" => "3",
        "dependency_count" => "1",
        "state_count" => "3",
        "transition_count" => "3",
        "requests" => %{
          "0" => %{"name" => "start", "meaning" => ""},
          "1" => %{"name" => "stop", "meaning" => ""},
          "2" => %{"name" => "reset", "meaning" => ""}
        },
        "events" => %{
          "0" => %{"name" => "inspection_faulted", "meaning" => "Inspection forwarded"}
        },
        "commands" => %{},
        "signals" => %{
          "0" => %{"name" => "started", "meaning" => ""},
          "1" => %{"name" => "stopped", "meaning" => ""},
          "2" => %{"name" => "faulted", "meaning" => ""}
        },
        "dependencies" => %{
          "0" => %{
            "name" => "inspection_cell",
            "meaning" => "Inspection dependency",
            "skills" => "",
            "signals" => "faulted",
            "status" => "faulted, running"
          }
        },
        "states" => %{
          "0" => %{"name" => "idle", "initial?" => "true", "status" => "Idle", "meaning" => ""},
          "1" => %{
            "name" => "running",
            "initial?" => "false",
            "status" => "Running",
            "meaning" => ""
          },
          "2" => %{
            "name" => "faulted",
            "initial?" => "false",
            "status" => "Faulted",
            "meaning" => ""
          }
        },
        "transitions" => %{
          "0" => %{
            "source" => "idle",
            "family" => "request",
            "trigger" => "start",
            "destination" => "running",
            "meaning" => ""
          },
          "1" => %{
            "source" => "running",
            "family" => "request",
            "trigger" => "stop",
            "destination" => "idle",
            "meaning" => ""
          },
          "2" => %{
            "source" => "faulted",
            "family" => "request",
            "trigger" => "reset",
            "destination" => "idle",
            "meaning" => ""
          }
        }
      }
    })

    render_click(view, "set_editor_mode", %{"mode" => "source"})

    html = render(view)

    assert html =~ "Packaging line supervisor"
    assert html =~ "uses do"
    assert html =~ "dependency(:inspection_cell"
    assert html =~ "event(:inspection_faulted"
  end
end
