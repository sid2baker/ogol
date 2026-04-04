defmodule Ogol.Studio.Examples do
  @moduledoc false

  alias Ogol.HMI.Surface.Defaults, as: SurfaceDefaults
  alias Ogol.Session
  alias Ogol.Session.RevisionFile

  @type example :: %{
          id: String.t(),
          title: String.t(),
          summary: String.t(),
          artifact_summary: String.t(),
          target_note: String.t(),
          machine_id: String.t() | nil,
          topology_id: String.t() | nil,
          sequence_id: String.t() | nil
        }

  @examples [
    %{
      id: "pump_skid_commissioning_bench",
      title: "Pump Skid Commissioning Bench",
      summary:
        "A real EtherCAT commissioning bench with one EK1100 coupler, one EL1809 input card, one EL2809 output card, a wired output-to-input loopback harness, four hardware-bound machines, and one commissioning sequence.",
      artifact_summary: "1 hardware, 1 simulator config, 4 machines, 1 topology, 1 sequence",
      target_note:
        "Use it as the canonical hardware-backed example. On a real bench, wire EL2809 ch1..ch6 into EL1809 ch1..ch6. In simulation, the checked-in simulator config creates those same loopback connections explicitly.",
      machine_id: "transfer_pump",
      topology_id: "pump_skid_bench",
      sequence_id: "pump_skid_commissioning"
    }
  ]

  @spec list() :: [example()]
  def list, do: @examples

  @spec fetch(String.t()) :: {:ok, example()} | {:error, :unknown_example}
  def fetch(id) when is_binary(id) do
    case Enum.find(@examples, &(&1.id == id)) do
      %{id: ^id} = example -> {:ok, example}
      nil -> {:error, :unknown_example}
    end
  end

  @spec revision_source(String.t()) :: {:ok, String.t()} | {:error, term()}
  def revision_source(id) when is_binary(id) do
    with {:ok, example} <- fetch(id),
         {:ok, source} <- File.read(revision_path(example)) do
      {:ok, source}
    end
  end

  @spec load_into_workspace(String.t(), keyword()) ::
          {:ok, example(), RevisionFile.t(), %{mode: RevisionFile.load_mode()}} | {:error, term()}
  def load_into_workspace(id, opts \\ []) when is_binary(id) do
    with {:ok, example} <- fetch(id),
         {:ok, source} <- revision_source(id),
         {:ok, %RevisionFile{} = revision_file, report} <-
           RevisionFile.load_into_workspace(source, opts),
         :ok <- maybe_populate_hmi_surfaces(example, revision_file) do
      _ = Session.set_loaded_revision_id(revision_file.revision)
      {:ok, example, revision_file, report}
    end
  end

  @spec revision_path(example()) :: String.t()
  def revision_path(%{id: id}) do
    Application.app_dir(:ogol, "priv/examples/#{id}.ogol.ex")
  end

  defp maybe_populate_hmi_surfaces(%{topology_id: topology_id}, %RevisionFile{} = revision_file)
       when is_binary(topology_id) do
    case RevisionFile.artifacts(revision_file, :hmi_surface) do
      [] ->
        Session.replace_hmi_surfaces(
          SurfaceDefaults.drafts_from_workspace(topology_id: topology_id)
        )

      _artifacts ->
        :ok
    end
  end

  defp maybe_populate_hmi_surfaces(_example, _revision_file), do: :ok
end
