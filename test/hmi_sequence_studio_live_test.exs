defmodule Ogol.HMI.SequenceStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.RevisionFile
  alias Ogol.Studio.Examples
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Studio.WorkspaceStore

  test "renders an empty sequence workspace and lets draft mode create a new sequence" do
    {:ok, view, html} = live(build_conn(), "/studio/sequences")

    assert html =~ "Sequence Studio"
    assert html =~ "The current workspace does not contain any sequences"
    assert has_element?(view, "button", "New")

    render_click(view, "new_sequence", %{})

    assert_patch(view, "/studio/sequences/sequence_1")

    html = render(view)
    assert html =~ "Compile"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "PackagingLine"
    assert html =~ "Available Machines"
    assert html =~ "packaging_line"
    assert html =~ "Skills"
    assert html =~ "Status"
    assert html =~ "Signals"
    assert html =~ "Visual Builder"
    assert html =~ "Compile the machine first to expose its skills"
  end

  test "switches between visual and source views for a sequence draft" do
    draft = WorkspaceStore.create_sequence("watering_auto")

    {:ok, view, html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    assert html =~ "watering_auto"
    assert html =~ "Root Flow"
    assert has_element?(view, "[data-test='sequence-view-source']")

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)
    assert html =~ "defmodule Ogol.Generated.Sequences.WateringAuto do"
    assert html =~ "use Ogol.Sequence"
  end

  test "compiles the current sequence source against the current workspace topology" do
    {:ok, revision_source} = RevisionFile.export_current(app_id: "sequences")

    assert {:ok, _revision_file, %{mode: :initial}} =
             RevisionFile.load_into_workspace(revision_source)

    draft = WorkspaceStore.create_sequence("watering_auto")

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    render_click(view, "request_transition", %{"transition" => "compile"})

    html = render(view)

    assert html =~ "Compiled"
    assert html =~ "Compiled Canonical Model"
    assert WorkspaceStore.fetch_sequence("watering_auto").compile_diagnostics == []
  end

  test "visual builder can add procedures and common steps from the current machine contract surface" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace("sequence_starter_cell")

    {:ok, view, html} = live(build_conn(), "/studio/sequences/sequence_starter_auto")

    assert html =~ "Visual Builder"
    assert html =~ "feeder"
    assert html =~ "clamp"
    assert html =~ "inspector"

    render_submit(view, "add_sequence_procedure", %{
      "procedure" => %{"name" => "shutdown", "meaning" => "Return the cell to ready"}
    })

    render_change(view, "change_step_builder", %{
      "builder" => %{
        "target" => "procedure",
        "target_procedure" => "shutdown",
        "kind" => "do_skill",
        "machine" => "inspector",
        "skill" => "reset",
        "status" => "ready?",
        "run_procedure" => "shutdown",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Reset inspector"
      }
    })

    render_submit(view, "add_sequence_step", %{
      "builder" => %{
        "target" => "procedure",
        "target_procedure" => "shutdown",
        "kind" => "do_skill",
        "machine" => "inspector",
        "skill" => "reset",
        "status" => "ready?",
        "run_procedure" => "shutdown",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Reset inspector"
      }
    })

    render_change(view, "change_step_builder", %{
      "builder" => %{
        "target" => "root",
        "target_procedure" => "shutdown",
        "kind" => "run",
        "machine" => "inspector",
        "skill" => "reset",
        "status" => "ready?",
        "run_procedure" => "shutdown",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Run shutdown"
      }
    })

    render_submit(view, "add_sequence_step", %{
      "builder" => %{
        "target" => "root",
        "target_procedure" => "shutdown",
        "kind" => "run",
        "machine" => "inspector",
        "skill" => "reset",
        "status" => "ready?",
        "run_procedure" => "shutdown",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Run shutdown"
      }
    })

    html = render(view)

    assert html =~ ":shutdown"
    assert html =~ "inspector.reset"
    assert html =~ "Run shutdown"

    source = WorkspaceStore.fetch_sequence("sequence_starter_auto").source
    assert source =~ "proc :shutdown, meaning: \"Return the cell to ready\" do"
    assert source =~ "do_skill(:inspector, :reset, meaning: \"Reset inspector\")"
    assert source =~ "run(:shutdown, meaning: \"Run shutdown\")"
  end

  test "source edits degrade honestly when the sequence leaves the supported visual subset" do
    draft = WorkspaceStore.create_sequence("watering_auto")

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    unsupported_source = """
    defmodule Ogol.Generated.Sequences.WateringAuto do
      use Ogol.Sequence

      sequence do
        name(:watering_auto)
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

  test "revision query loads sequence artifacts into the shared workspace session" do
    draft = WorkspaceStore.create_sequence("revision_sequence")
    {:ok, _revision} = Ogol.Studio.RevisionStore.deploy_current(app_id: "sequences")

    :ok = WorkspaceStore.reset_sequences()

    {:ok, _view, html} = live(build_conn(), "/studio/sequences?revision=r1")

    assert html =~ SequenceSource.summary(draft.model)
    assert html =~ "Selecting a revision loads it into the shared workspace session"
    assert html =~ "Available Machines"
    assert html =~ "packaging_line"
    assert WorkspaceStore.fetch_sequence("revision_sequence").model == draft.model
  end
end
