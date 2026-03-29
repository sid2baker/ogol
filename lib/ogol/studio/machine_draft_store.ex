defmodule Ogol.Studio.MachineDraftStore do
  @moduledoc false

  use GenServer

  alias Ogol.Studio.MachineDefinition

  @table :ogol_studio_machine_drafts
  @default_ids ["packaging_line", "inspection_cell", "palletizer_cell"]

  defmodule Draft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: map() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()],
            saved_at: DateTime.t() | nil
          }

    defstruct [:id, :source, :model, :saved_at, sync_state: :synced, sync_diagnostics: []]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ensure_started do
    case :ets.whereis(@table) do
      :undefined ->
        case Process.whereis(__MODULE__) do
          nil ->
            case start_link() do
              {:ok, _pid} -> :ok
              {:error, {:already_started, _pid}} -> :ok
            end

          _pid ->
            wait_for_table()
        end

      _ ->
        :ok
    end
  end

  def default_id, do: hd(@default_ids)

  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    seed_defaults()
  end

  def list_drafts do
    ensure_started()

    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.id)
  end

  def fetch(id) when is_binary(id) do
    ensure_started()

    case :ets.lookup(@table, id) do
      [{^id, %Draft{} = draft}] -> draft
      _ -> nil
    end
  end

  def ensure_draft(id) when is_binary(id) do
    fetch(id) || seed_draft_for(id)
  end

  def create_draft(id \\ next_available_id()) do
    seed_draft_for(id)
  end

  def save_source(id, source, model, sync_state, sync_diagnostics) do
    update(id, fn draft ->
      %{
        draft
        | source: source,
          model: model,
          sync_state: sync_state,
          sync_diagnostics: sync_diagnostics,
          saved_at: DateTime.utc_now()
      }
    end)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    seed_defaults()
    {:ok, %{}}
  end

  defp seed_defaults do
    Enum.each(@default_ids, &seed_draft_for/1)
    :ok
  end

  defp seed_draft_for(id) do
    model = seed_model(id)
    source = MachineDefinition.to_source(model)

    draft = %Draft{
      id: id,
      source: source,
      model: model,
      sync_state: :synced,
      saved_at: DateTime.utc_now()
    }

    :ets.insert(@table, {draft.id, draft})
    draft
  end

  defp seed_model("inspection_cell") do
    MachineDefinition.default_model("inspection_cell")
    |> Map.put(:meaning, "Inspection cell coordinator")
    |> Map.put(:requests, [%{name: "start"}, %{name: "reject"}, %{name: "reset"}])
    |> Map.put(:signals, [%{name: "started"}, %{name: "rejected"}, %{name: "faulted"}])
    |> Map.put(:transitions, [
      %{
        source: "idle",
        family: "request",
        trigger: "start",
        destination: "running",
        meaning: nil
      },
      %{
        source: "running",
        family: "request",
        trigger: "reject",
        destination: "faulted",
        meaning: nil
      },
      %{source: "faulted", family: "request", trigger: "reset", destination: "idle", meaning: nil}
    ])
  end

  defp seed_model("palletizer_cell") do
    MachineDefinition.default_model("palletizer_cell")
    |> Map.put(:meaning, "Palletizer cell coordinator")
    |> Map.put(:requests, [%{name: "arm"}, %{name: "stop"}, %{name: "reset"}])
    |> Map.put(:signals, [%{name: "armed"}, %{name: "stopped"}, %{name: "faulted"}])
    |> Map.put(:transitions, [
      %{source: "idle", family: "request", trigger: "arm", destination: "running", meaning: nil},
      %{source: "running", family: "request", trigger: "stop", destination: "idle", meaning: nil},
      %{source: "faulted", family: "request", trigger: "reset", destination: "idle", meaning: nil}
    ])
  end

  defp seed_model(id), do: MachineDefinition.default_model(id)

  defp next_available_id do
    existing_ids = list_drafts() |> Enum.map(& &1.id) |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = "machine_#{index}"
      if MapSet.member?(existing_ids, candidate), do: nil, else: candidate
    end)
  end

  defp update(id, fun) do
    draft = ensure_draft(id)
    updated = fun.(draft)
    :ets.insert(@table, {id, updated})
    updated
  end

  defp wait_for_table do
    case :ets.whereis(@table) do
      :undefined ->
        Process.sleep(10)
        wait_for_table()

      _ ->
        :ok
    end
  end
end
