defmodule Ogol.MachineAuthoringCorpusTest do
  use ExUnit.Case, async: true

  @corpus_root Path.expand("../../fixtures/machine_authoring", __DIR__)
  @manifest_path Path.join(@corpus_root, "manifest.term")

  defp manifest do
    {fixtures, _binding} =
      @manifest_path
      |> File.read!()
      |> Code.eval_string()

    fixtures
  end

  test "all manifest entries reference existing files" do
    for fixture <- manifest() do
      path = Path.join(@corpus_root, fixture.path)
      assert File.exists?(path), "missing corpus fixture: #{path}"
    end
  end

  test "corpus covers the planned compatibility and lifecycle boundaries" do
    fixtures = manifest()

    assert length(fixtures) >= 10

    assert MapSet.subset?(
             MapSet.new([:fully_editable, :partially_representable, :not_visually_editable]),
             fixtures |> Enum.map(& &1.expected.classification) |> MapSet.new()
           )

    assert MapSet.subset?(
             MapSet.new([:hand_authored, :model_originated]),
             fixtures |> Enum.map(& &1.origin) |> MapSet.new()
           )

    assert Enum.any?(fixtures, &(&1.expected.runtime == :activates))
    assert Enum.any?(fixtures, &(&1.expected.runtime == :not_exercised))

    canonical_groups =
      fixtures
      |> Enum.filter(& &1.canonical_group)
      |> Enum.group_by(& &1.canonical_group)

    assert map_size(canonical_groups) >= 2
    assert Enum.all?(canonical_groups, fn {_group, members} -> length(members) >= 2 end)
  end
end
