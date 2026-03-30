defmodule Ogol.Studio.SequenceDraftStore do
  @moduledoc false

  use GenServer

  alias Ogol.Sequence.Model
  alias Ogol.Studio.Build
  alias Ogol.Studio.SequenceDefinition

  @table :ogol_studio_sequence_drafts

  defmodule Draft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: map() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()],
            validation_model: Model.t() | nil,
            validation_diagnostics: [String.t()],
            validated_source_digest: String.t() | nil,
            saved_at: DateTime.t() | nil
          }

    defstruct [
      :id,
      :source,
      :model,
      :validation_model,
      :validated_source_digest,
      :saved_at,
      sync_state: :synced,
      sync_diagnostics: [],
      validation_diagnostics: []
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

  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
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

  def ensure_draft(id) when is_binary(id), do: fetch(id) || seed_draft_for(id)

  def create_draft(id \\ next_available_id()) do
    seed_draft_for(id)
  end

  def save_source(id, source, model, sync_state, sync_diagnostics) do
    update(id, fn draft ->
      source_digest = Build.digest(source)
      validation_stale? = draft.validated_source_digest != source_digest

      %{
        draft
        | source: source,
          model: model,
          sync_state: sync_state,
          sync_diagnostics: sync_diagnostics,
          validation_model: if(validation_stale?, do: nil, else: draft.validation_model),
          validation_diagnostics:
            if(validation_stale?, do: [], else: draft.validation_diagnostics),
          validated_source_digest:
            if(validation_stale?, do: nil, else: draft.validated_source_digest),
          saved_at: DateTime.utc_now()
      }
    end)
  end

  def record_validation(id, validation_model, diagnostics, source_digest) do
    update(id, fn draft ->
      %{
        draft
        | validation_model: validation_model,
          validation_diagnostics: diagnostics,
          validated_source_digest: source_digest,
          saved_at: DateTime.utc_now()
      }
    end)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  defp seed_draft_for(id) do
    source = SequenceDefinition.default_source(id)

    {model, sync_state, sync_diagnostics} =
      case SequenceDefinition.from_source(source) do
        {:ok, model} -> {model, :synced, []}
        {:error, diagnostics} -> {nil, :unsupported, diagnostics}
      end

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

  defp next_available_id do
    existing_ids = list_drafts() |> Enum.map(& &1.id) |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = "sequence_#{index}"
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
