defmodule Ogol.HMI.MachineStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Session

  test "renders the machine library on the left and the selected studio cell in the middle" do
    {:ok, view, html} = live(build_conn(), "/studio/machines/packaging_line")

    assert html =~ "Machine Studio"
    assert html =~ "Machines"
    assert html =~ "Packaging Line coordinator"
    assert html =~ "Inspection cell coordinator"
    assert html =~ "Config"
    assert html =~ "Code"
    assert html =~ "Compile"
    assert has_element?(view, ~s([phx-hook="MermaidDiagram"]))
    assert has_element?(view, "[data-test='machine-view-config']")
    assert has_element?(view, "[data-test='machine-view-source']")
    assert has_element?(view, "button", "New")
  end

  test "switches to code view in place for the selected machine" do
    {:ok, view, _html} = live(build_conn(), "/studio/machines/packaging_line")

    render_click(view, "select_view", %{"view" => "source"})

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
    {:ok, view, _html} = live(build_conn(), "/studio/machines/packaging_line")

    render_click(view, "new_machine", %{})

    assert_patch(view, "/studio/machines/machine_1")
    assert render(view) =~ "machine_1"
  end

  test "deleting the selected machine patches to the next available machine" do
    draft = Session.create_machine("browser_delete_machine")

    {:ok, view, _html} = live(build_conn(), "/studio/machines/#{draft.id}")

    render_click(view, "request_transition", %{"transition" => "delete"})

    expected_path =
      case Session.list_machines() do
        [%{id: id} | _rest] -> "/studio/machines/#{id}"
        [] -> "/studio/machines"
      end

    assert_patch(view, expected_path)
    refute Enum.any?(Session.list_machines(), &(&1.id == draft.id))
  end

  test "keeps config view and shows a projection when the machine source leaves the supported subset" do
    {:ok, view, _html} = live(build_conn(), "/studio/machines/packaging_line")

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

    assert html =~ "Config Projection"
    assert html =~ "Source uses features outside the first editor"
    assert html =~ "Memory Fields"
    assert html =~ "retry_count"
    refute has_element?(view, "textarea[name='draft[source]']")
  end

  test "visual edits update the selected machine draft" do
    {:ok, view, _html} = live(build_conn(), "/studio/machines/packaging_line")

    render_change(view, "change_visual", %{
      "machine" => %{
        "machine_id" => "packaging_line",
        "module_name" => "Ogol.Generated.Machines.PackagingLine",
        "meaning" => "Packaging line supervisor",
        "request_count" => "3",
        "event_count" => "1",
        "command_count" => "0",
        "signal_count" => "3",
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

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)

    assert html =~ "Packaging line supervisor"
    assert html =~ "event(:inspection_faulted"
  end

  test "visual edits compile the selected machine draft into the runtime" do
    {:ok, view, _html} = live(build_conn(), "/studio/machines/packaging_line")

    render_change(view, "change_visual", %{
      "machine" => %{
        "machine_id" => "packaging_line",
        "module_name" => "Ogol.Generated.Machines.PackagingLine",
        "meaning" => "Packaging line supervisor",
        "request_count" => "3",
        "event_count" => "0",
        "command_count" => "0",
        "signal_count" => "3",
        "state_count" => "3",
        "transition_count" => "3",
        "requests" => %{
          "0" => %{"name" => "start", "meaning" => ""},
          "1" => %{"name" => "stop", "meaning" => ""},
          "2" => %{"name" => "reset", "meaning" => ""}
        },
        "events" => %{},
        "commands" => %{},
        "signals" => %{
          "0" => %{"name" => "started", "meaning" => ""},
          "1" => %{"name" => "stopped", "meaning" => ""},
          "2" => %{"name" => "faulted", "meaning" => ""}
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

    render_click(view, "request_transition", %{"transition" => "compile"})
    refute render(view) =~ "Compile failed"

    assert {:ok, module} = Ogol.Runtime.current(:machine, "packaging_line")
    assert inspect(module) =~ "PackagingLine"
  end
end
