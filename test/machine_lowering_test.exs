defmodule Ogol.MachineLoweringTest do
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

  defp semantic_projection(model) do
    model
    |> Map.from_struct()
    |> Map.put(:module, nil)
    |> Map.put(:source_path, nil)
    |> Map.put(:provenance_index, %{})
    |> normalize_term()
  end

  defp normalize_term(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.map(fn {key, value} ->
      if key == :provenance, do: {key, nil}, else: {key, normalize_term(value)}
    end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp normalize_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, normalize_term(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp normalize_term(list) when is_list(list), do: Enum.map(list, &normalize_term/1)
  defp normalize_term(other), do: other

  test "fully editable corpus fixtures lower into machine models" do
    for fixture <- Enum.filter(manifest(), &(&1.expected.classification == :fully_editable)) do
      path = Path.join(@corpus_root, fixture.path)
      assert {:ok, model} = MachineSource.load_model_file(path)
      assert model.compatibility == :fully_editable
      assert model.module
      assert model.states.initial_state
    end
  end

  test "partial and rejected corpus fixtures do not lower into editable models" do
    for fixture <- Enum.reject(manifest(), &(&1.expected.classification == :fully_editable)) do
      path = Path.join(@corpus_root, fixture.path)
      assert {:error, artifact} = MachineSource.load_model_file(path)
      assert artifact.compatibility == fixture.expected.classification
    end
  end

  test "canonical groups lower to equivalent semantic models" do
    manifest()
    |> Enum.filter(& &1.canonical_group)
    |> Enum.group_by(& &1.canonical_group)
    |> Enum.each(fn {_group, fixtures} ->
      [first | rest] =
        Enum.map(fixtures, fn fixture ->
          path = Path.join(@corpus_root, fixture.path)
          {:ok, model} = MachineSource.load_model_file(path)
          semantic_projection(model)
        end)

      Enum.each(rest, fn other ->
        assert other == first
      end)
    end)
  end

  test "lowered hardware opts are normalized to deterministic key order" do
    path = Path.join(@corpus_root, "fully_editable/literal_hardware_opts_reordered.ogol")
    assert {:ok, model} = MachineSource.load_model_file(path)

    assert model.metadata.hardware_opts == [
             observe_events?: true,
             retry_backoff_ms: 250,
             tags: [:lab, :test]
           ]
  end

  test "lowering preserves public skill and status projection metadata" do
    path = Path.join(@corpus_root, "fully_editable/public_interface_surface_canonical.ogol")
    assert {:ok, model} = MachineSource.load_model_file(path)

    assert model.boundary.facts[:enabled?].public? == true
    assert model.boundary.outputs[:running?].public? == true
    assert model.memory.fields[:count].public? == true
    assert model.boundary.events[:mark_seen].skill? == true
    assert model.boundary.requests[:start].skill? == true
    assert model.boundary.requests[:reset].skill? == false
  end
end
