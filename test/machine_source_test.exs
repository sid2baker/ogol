defmodule Ogol.MachineSourceTest do
  use ExUnit.Case, async: true

  alias Ogol.Authoring.MachineSource

  @corpus_root Path.expand("fixtures/machine_authoring", __DIR__)
  @manifest_path Path.join(@corpus_root, "manifest.term")

  defp manifest do
    {fixtures, _binding} =
      @manifest_path
      |> File.read!()
      |> Code.eval_string()

    fixtures
  end

  test "classifier matches expected compatibility for the compact corpus" do
    for fixture <- manifest() do
      path = Path.join(@corpus_root, fixture.path)

      assert {:ok, artifact} = MachineSource.load_file(path)

      assert artifact.compatibility == fixture.expected.classification,
             """
             fixture #{fixture.id} expected #{inspect(fixture.expected.classification)} \
             but got #{inspect(artifact.compatibility)}
             diagnostics: #{inspect(artifact.diagnostics, pretty: true)}
             """
    end
  end
end
