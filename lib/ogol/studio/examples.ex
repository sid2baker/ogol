defmodule Ogol.Studio.Examples do
  @moduledoc false

  alias Ogol.Studio.Bundle

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
      id: "watering_valves",
      title: "Watering Valves",
      summary:
        "Four irrigation valves with rotating scheduled watering, manual override, and a hard at-most-two-open safety rule.",
      artifact_summary: "1 machine, 1 topology",
      target_note:
        "Target setup is still separate. To run it in Studio, configure EtherCAT or Simulator with one output slave exposing valve_1_open? through valve_4_open?.",
      machine_id: "watering_controller",
      topology_id: "watering_system",
      sequence_id: nil
    },
    %{
      id: "sequence_starter_cell",
      title: "Sequence Starter Cell",
      summary:
        "Three machine contracts, one topology, and one starter sequence for Sequence Studio authoring over public machine skills and durable status.",
      artifact_summary: "3 machines, 1 topology, 1 sequence",
      target_note:
        "No target setup is required. This bundle is pure machine, topology, and sequence source, so you can load it and start editing sequences immediately.",
      machine_id: nil,
      topology_id: "sequence_starter_cell",
      sequence_id: "sequence_starter_auto"
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

  @spec bundle_source(String.t()) :: {:ok, String.t()} | {:error, term()}
  def bundle_source(id) when is_binary(id) do
    with {:ok, example} <- fetch(id),
         {:ok, source} <- File.read(bundle_path(example)) do
      {:ok, source}
    end
  end

  @spec import_into_stores(String.t(), keyword()) ::
          {:ok, example(), Bundle.t(), %{mode: Bundle.load_mode()}} | {:error, term()}
  def import_into_stores(id, opts \\ []) when is_binary(id) do
    with {:ok, example} <- fetch(id),
         {:ok, source} <- bundle_source(id),
         {:ok, %Bundle{} = bundle, report} <- Bundle.import_into_stores(source, opts) do
      {:ok, example, bundle, report}
    end
  end

  @spec bundle_path(example()) :: String.t()
  def bundle_path(%{id: id}) do
    Application.app_dir(:ogol, "priv/examples/#{id}.ogol.ex")
  end
end
