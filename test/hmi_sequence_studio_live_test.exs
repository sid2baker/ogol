defmodule Ogol.HMI.SequenceStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.Examples
  alias Ogol.Studio.SequenceDefinition
  alias Ogol.Studio.SequenceDraftStore

  test "renders an empty sequence workspace and lets draft mode create a new sequence" do
    {:ok, view, html} = live(build_conn(), "/studio/sequences")

    assert html =~ "Sequence Studio"
    assert html =~ "The current bundle does not contain any sequences"
    assert has_element?(view, "button", "New")

    render_click(view, "new_sequence", %{})

    assert_patch(view, "/studio/sequences/sequence_1")

    html = render(view)
    assert html =~ "Validate"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "PackagingLine"
    assert html =~ "Available Machines"
    assert html =~ "packaging_line"
    assert html =~ "Skills"
    assert html =~ "Status"
    assert html =~ "Signals"
    assert html =~ "Visual Builder"
    assert html =~ "start"
    assert html =~ "started"
  end

  test "switches between visual and source views for a sequence draft" do
    draft = SequenceDraftStore.create_draft("watering_auto")

    {:ok, view, html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    assert html =~ "watering_auto"
    assert html =~ "Root Flow"
    assert has_element?(view, "[data-test='sequence-view-source']")

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)
    assert html =~ "defmodule Ogol.Generated.Sequences.WateringAuto do"
    assert html =~ "use Ogol.Sequence"
  end

  test "validates the current sequence source against the current draft topology bundle" do
    draft = SequenceDraftStore.create_draft("watering_auto")

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    render_click(view, "request_transition", %{"transition" => "validate"})

    html = render(view)

    assert html =~ "Validated"
    assert html =~ "Validated Canonical Model"
    assert SequenceDraftStore.fetch("watering_auto").validation_model != nil
  end

  test "visual builder can add procedures and common steps from the current machine contract surface" do
    {:ok, _example, _bundle} = Examples.import_into_stores("sequence_starter_cell")

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

    source = SequenceDraftStore.fetch("sequence_starter_auto").source
    assert source =~ "proc :shutdown, meaning: \"Return the cell to ready\" do"
    assert source =~ "do_skill(:inspector, :reset, meaning: \"Reset inspector\")"
    assert source =~ "run(:shutdown, meaning: \"Run shutdown\")"
  end

  test "source edits degrade honestly when the sequence leaves the supported visual subset" do
    draft = SequenceDraftStore.create_draft("watering_auto")

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

  test "revision mode reads sequence artifacts from the selected bundle" do
    draft = SequenceDraftStore.create_draft("revision_sequence")
    {:ok, _revision} = Ogol.Studio.RevisionStore.deploy_current(app_id: "sequences")

    :ok = SequenceDraftStore.reset()

    {:ok, _view, html} = live(build_conn(), "/studio/sequences?revision=r1")

    assert html =~ SequenceDefinition.summary(draft.model)
    assert html =~ "Saved revisions are read-only"
    assert html =~ "Available Machines"
    assert html =~ "packaging_line"
  end
end
