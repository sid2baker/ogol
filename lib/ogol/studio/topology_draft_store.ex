defmodule Ogol.Studio.TopologyDraftStore do
  @moduledoc false

  use GenServer

  alias Ogol.Studio.DemoSeed
  alias Ogol.Studio.TopologyDefinition

  @table :ogol_studio_topology_drafts
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

  def default_id, do: hd(default_ids())

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

  def ensure_draft(id) when is_binary(id), do: fetch(id) || seed_draft_for(id)

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
    Enum.each(default_ids(), &seed_draft_for/1)
    :ok
  end

  defp seed_draft_for(id) do
    %{model: model, source: source, sync_state: sync_state, sync_diagnostics: sync_diagnostics} =
      seed_draft(id)

    draft = %Draft{
      id: id,
      source: source,
      model: model,
      sync_state: sync_state,
      sync_diagnostics: sync_diagnostics,
      saved_at: DateTime.utc_now()
    }

    :ets.insert(@table, {draft.id, draft})
    draft
  end

  defp seed_draft(id) do
    case DemoSeed.topology_draft(id) do
      nil ->
        model = TopologyDefinition.default_model(id)

        %{
          model: model,
          source: TopologyDefinition.to_source(model),
          sync_state: :synced,
          sync_diagnostics: []
        }

      draft ->
        draft
    end
  end

  defp next_available_id do
    existing_ids = list_drafts() |> Enum.map(& &1.id) |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = "topology_#{index}"
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

  defp default_ids do
    @default_ids ++ DemoSeed.topology_ids()
  end
end
