defmodule Ogol.MachinePrinterTest do
  use ExUnit.Case, async: true

  alias Ogol.Authoring.MachinePrinter
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

  test "printer output round-trips through lowering for fully editable fixtures" do
    for fixture <- Enum.filter(manifest(), &(&1.expected.classification == :fully_editable)) do
      path = Path.join(@corpus_root, fixture.path)

      {:ok, model} = MachineSource.load_model_file(path)
      printed = MachinePrinter.print(model)
      {:ok, reparsed_model} = MachineSource.load_model_source(printed)

      assert semantic_projection(reparsed_model) == semantic_projection(model)
    end
  end

  test "canonical groups print to identical canonical source" do
    manifest()
    |> Enum.filter(& &1.canonical_group)
    |> Enum.group_by(& &1.canonical_group)
    |> Enum.each(fn {_group, fixtures} ->
      [first | rest] =
        Enum.map(fixtures, fn fixture ->
          path = Path.join(@corpus_root, fixture.path)
          {:ok, model} = MachineSource.load_model_file(path)
          MachinePrinter.print(model)
        end)

      Enum.each(rest, fn other ->
        assert other == first
      end)
    end)
  end

  test "printer preserves public interface metadata canonically" do
    path = Path.join(@corpus_root, "fully_editable/public_interface_surface_canonical.ogol")
    {:ok, model} = MachineSource.load_model_file(path)
    printed = MachinePrinter.print(model)

    assert printed =~ "event(:mark_seen, meaning: \"Public async skill\", skill?: true)"
    assert printed =~ "request(:reset, meaning: \"Private reset request\", skill?: false)"

    assert printed =~
             "fact(:enabled?, :boolean, default: true, meaning: \"Enable fact\", public?: true)"

    assert printed =~
             "output(:running?, :boolean, default: false, meaning: \"Run output\", public?: true)"

    assert printed =~
             "field(:count, :integer, default: 0, meaning: \"Visible counter\", public?: true)"
  end
end
