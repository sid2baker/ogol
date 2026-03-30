defmodule Ogol.Studio.DriverDraftStore do
  @moduledoc false

  use GenServer

  alias Ogol.Studio.Build.Artifact
  alias Ogol.Studio.DriverDefinition

  @table :ogol_studio_driver_drafts
  @default_id "packaging_outputs"

  defmodule Draft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: map() | nil,
            sync_state: :synced | :partial | :unsupported,
            sync_diagnostics: [term()],
            build_artifact: Artifact.t() | nil,
            build_diagnostics: [term()],
            saved_at: DateTime.t() | nil
          }

    defstruct [
      :id,
      :source,
      :model,
      :build_artifact,
      :saved_at,
      sync_state: :synced,
      sync_diagnostics: [],
      build_diagnostics: []
    ]
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

  def default_id, do: @default_id

  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    seed_defaults()
  end

  def replace_drafts(drafts) when is_list(drafts) do
    ensure_started()
    :ets.delete_all_objects(@table)

    Enum.each(drafts, fn %Draft{} = draft ->
      :ets.insert(@table, {draft.id, draft})
    end)

    :ok
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
      source_changed? = draft.source != source

      %{
        draft
        | source: source,
          model: model,
          sync_state: sync_state,
          sync_diagnostics: sync_diagnostics,
          build_artifact: if(source_changed?, do: nil, else: draft.build_artifact),
          build_diagnostics: if(source_changed?, do: [], else: draft.build_diagnostics),
          saved_at: DateTime.utc_now()
      }
    end)
  end

  def record_build(id, artifact, diagnostics) do
    update(id, fn draft ->
      %{draft | build_artifact: artifact, build_diagnostics: diagnostics}
    end)
  end

  def current_status_snapshot(id) do
    case Ogol.Studio.Modules.status(id) do
      {:ok, status} -> status
      {:error, :not_found} -> nil
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    seed_defaults()
    {:ok, %{}}
  end

  defp seed_defaults do
    draft = build_seeded_draft(@default_id)
    :ets.insert(@table, {draft.id, draft})
    :ok
  end

  defp seed_draft_for(id) do
    draft = build_seeded_draft(id)
    :ets.insert(@table, {draft.id, draft})
    draft
  end

  defp build_seeded_draft(id) do
    model = DriverDefinition.default_model(id)

    source =
      DriverDefinition.to_source(DriverDefinition.module_from_name!(model.module_name), model)

    %Draft{
      id: id,
      source: source,
      model: model,
      sync_state: :synced,
      saved_at: DateTime.utc_now()
    }
  end

  defp next_available_id do
    existing_ids = list_drafts() |> Enum.map(& &1.id) |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = "driver_#{index}"
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
