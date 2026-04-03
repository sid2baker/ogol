defmodule Ogol.HMI.SequenceStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Session.RevisionFile
  alias Ogol.Studio.Examples
  alias Ogol.Session

  @example_id "pump_skid_commissioning_bench"

  test "renders an empty sequence workspace and lets draft mode create a new sequence" do
    {:ok, _example, _revision_file, _report} = Examples.load_into_workspace(@example_id)
    :ok = Session.reset_sequences()

    {:ok, view, html} = live(build_conn(), "/studio/sequences")

    assert html =~ "Sequence Studio"
    assert html =~ "No sequences in the current workspace."
    assert has_element?(view, "button", "New")

    render_click(view, "new_sequence", %{})

    assert_patch(view, "/studio/sequences/sequence_1")

    html = render(view)
    assert html =~ "Compile"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "PumpSkidBench"
    assert html =~ "Available Machines"
    assert html =~ "transfer_pump"
    assert html =~ "Skills"
    assert html =~ "Status"
    assert html =~ "Signals"
    assert html =~ "Visual Builder"
  end

  test "switches between visual and source views for a sequence draft" do
    draft = Session.create_sequence("pump_skid_manual")

    {:ok, view, html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    assert html =~ "pump_skid_manual"
    assert html =~ "Root Flow"
    assert has_element?(view, "[data-test='sequence-view-source']")

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)
    assert html =~ "defmodule Ogol.Generated.Sequences.PumpSkidManual do"
    assert html =~ "use Ogol.Sequence"
  end

  test "deleting the selected sequence patches to the next available sequence page" do
    draft = Session.create_sequence("browser_delete_sequence")

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    render_click(view, "request_transition", %{"transition" => "delete"})

    expected_path =
      case Session.list_sequences() do
        [%{id: id} | _rest] -> "/studio/sequences/#{id}"
        [] -> "/studio/sequences"
      end

    assert_patch(view, expected_path)
    refute Enum.any?(Session.list_sequences(), &(&1.id == draft.id))
  end

  test "compiles the current sequence source against the current workspace topology" do
    {:ok, revision_source} = RevisionFile.export_current(app_id: "sequences")

    assert {:ok, _revision_file, %{mode: :initial}} =
             RevisionFile.load_into_workspace(revision_source)

    draft = Session.create_sequence("pump_skid_manual")

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    render_click(view, "request_transition", %{"transition" => "compile"})

    html = render(view)

    assert html =~ "Compiled"
    assert html =~ "Compiled Canonical Model"
  end

  test "visual builder can add procedures and common steps from the current machine contract surface" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    {:ok, view, html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    assert html =~ "Visual Builder"
    assert html =~ "supply_valve"
    assert html =~ "return_valve"
    assert html =~ "transfer_pump"

    render_submit(view, "add_sequence_procedure", %{
      "procedure" => %{"name" => "alarm_reset", "meaning" => "Clear the alarm path"}
    })

    render_change(view, "change_step_builder", %{
      "builder" => %{
        "target" => "procedure",
        "target_procedure" => "alarm_reset",
        "kind" => "do_skill",
        "machine" => "alarm_stack",
        "skill" => "clear",
        "status" => "green_fb?",
        "run_procedure" => "alarm_reset",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Clear alarm stack"
      }
    })

    render_submit(view, "add_sequence_step", %{
      "builder" => %{
        "target" => "procedure",
        "target_procedure" => "alarm_reset",
        "kind" => "do_skill",
        "machine" => "alarm_stack",
        "skill" => "clear",
        "status" => "green_fb?",
        "run_procedure" => "alarm_reset",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Clear alarm stack"
      }
    })

    render_change(view, "change_step_builder", %{
      "builder" => %{
        "target" => "root",
        "target_procedure" => "alarm_reset",
        "kind" => "run",
        "machine" => "alarm_stack",
        "skill" => "clear",
        "status" => "green_fb?",
        "run_procedure" => "alarm_reset",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Run alarm reset"
      }
    })

    render_submit(view, "add_sequence_step", %{
      "builder" => %{
        "target" => "root",
        "target_procedure" => "alarm_reset",
        "kind" => "run",
        "machine" => "alarm_stack",
        "skill" => "clear",
        "status" => "green_fb?",
        "run_procedure" => "alarm_reset",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Run alarm reset"
      }
    })

    html = render(view)

    assert html =~ ":alarm_reset"
    assert html =~ "alarm_stack.clear"
    assert html =~ "Run alarm reset"

    source = Session.fetch_sequence("pump_skid_commissioning").source
    assert source =~ "proc :alarm_reset, meaning: \"Clear the alarm path\" do"
    assert source =~ "do_skill(:alarm_stack, :clear, meaning: \"Clear alarm stack\")"
    assert source =~ "run(:alarm_reset, meaning: \"Run alarm reset\")"
  end

  test "new sequences in the commissioning example target the loaded topology and expose its machine contract" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    {:ok, view, _html} = live(build_conn(), "/studio/sequences")

    render_click(view, "new_sequence", %{})

    assert_patch(view, "/studio/sequences/sequence_1")

    html = render(view)

    assert html =~ "Ogol.Generated.Topologies.PumpSkidBench"
    assert html =~ "transfer_pump"

    assert has_element?(
             view,
             ~s(select[name="builder[machine]"] option[value="transfer_pump"])
           )
  end

  test "source edits degrade honestly when the sequence leaves the supported visual subset" do
    draft = Session.create_sequence("pump_skid_manual")

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    unsupported_source = """
    defmodule Ogol.Generated.Sequences.PumpSkidManual do
      use Ogol.Sequence

      sequence do
        name(:pump_skid_manual)
        topology(Ogol.Generated.Topologies.PackagingLine)

        if true do
          fail("unsupported")
        end
      end
    end
    """

    render_change(view, "change_source", %{"draft" => %{"source" => unsupported_source}})

    html = render(view)

    assert html =~ "Visual summary unavailable"
    assert html =~ "unsupported step constructs"
    assert has_element?(view, "[data-test='sequence-view-visual'][disabled]")
  end

  test "revision query is ignored and sequences still reflect the current workspace" do
    draft = Session.create_sequence("revision_sequence")
    revision_model = Map.put(draft.model, :meaning, "Revision sequence from saved workspace")

    Session.save_sequence_source(
      draft.id,
      SequenceSource.to_source(revision_model),
      revision_model,
      :synced,
      []
    )

    {:ok, _revision} = Ogol.Session.Revisions.save_current(app_id: "sequences")

    current_workspace_model =
      Session.fetch_sequence("revision_sequence").model
      |> Map.put(:meaning, "Current workspace sequence")

    Session.save_sequence_source(
      draft.id,
      SequenceSource.to_source(current_workspace_model),
      current_workspace_model,
      :synced,
      []
    )

    {:ok, _view, html} =
      live(build_conn(), "/studio/sequences/revision_sequence?app_id=sequences&revision=r1")

    assert html =~ "Sequence Studio"
    assert html =~ "Current workspace sequence"
    refute html =~ "Revision sequence from saved workspace"
  end
end
