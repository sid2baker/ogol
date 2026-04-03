defmodule Ogol.TestSupport.WorkspaceFixture do
  @moduledoc false

  alias Ogol.Session.RevisionFile

  @packaging_line_source_path Path.expand(
                                "../../../fixtures/revisions/packaging_line.ogol.ex",
                                __DIR__
                              )

  def load_packaging_line!(opts \\ []) do
    source = File.read!(@packaging_line_source_path)

    case RevisionFile.load_into_workspace(source, opts) do
      {:ok, revision_file, report} -> {:ok, revision_file, report}
      {:error, reason} -> raise "failed to load packaging line fixture: #{inspect(reason)}"
    end
  end

  def packaging_line_source do
    File.read!(@packaging_line_source_path)
  end
end
