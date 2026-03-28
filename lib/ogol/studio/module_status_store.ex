defmodule Ogol.Studio.ModuleStatusStore do
  @moduledoc false

  use GenServer

  @table :ogol_studio_module_status

  defmodule Entry do
    @moduledoc false

    @type t :: %__MODULE__{
            id: term(),
            module: module() | nil,
            apply_state: :draft | :built | :applied | :blocked,
            source_digest: String.t() | nil,
            built_source_digest: String.t() | nil,
            old_code: boolean(),
            blocked_reason: term() | nil,
            lingering_pids: [pid()],
            last_build_at: DateTime.t() | nil,
            last_apply_at: DateTime.t() | nil
          }

    defstruct [
      :id,
      :module,
      :source_digest,
      :built_source_digest,
      :blocked_reason,
      :last_build_at,
      :last_apply_at,
      apply_state: :draft,
      old_code: false,
      lingering_pids: []
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

  def fetch(id) do
    ensure_started()

    case :ets.lookup(@table, id) do
      [{^id, %Entry{} = entry}] -> entry
      _ -> nil
    end
  end

  def record_build(id, source_digest) do
    update(id, fn entry ->
      same_as_applied? =
        entry.source_digest &&
          entry.source_digest == source_digest &&
          entry.apply_state == :applied

      if same_as_applied? do
        %{
          entry
          | built_source_digest: source_digest,
            blocked_reason: nil,
            lingering_pids: [],
            old_code: old_code?(entry.module),
            last_build_at: DateTime.utc_now()
        }
      else
        %{
          entry
          | apply_state: :built,
            built_source_digest: source_digest,
            blocked_reason: nil,
            lingering_pids: [],
            old_code: old_code?(entry.module),
            last_build_at: DateTime.utc_now()
        }
      end
    end)
  end

  def mark_applied(id, module, source_digest) do
    update(id, fn entry ->
      %{
        entry
        | module: module,
          apply_state: :applied,
          source_digest: source_digest,
          built_source_digest: source_digest,
          old_code: old_code?(module),
          blocked_reason: nil,
          lingering_pids: [],
          last_apply_at: DateTime.utc_now()
      }
    end)
  end

  def mark_blocked(id, lingering_pids) do
    update(id, fn entry ->
      %{
        entry
        | apply_state: :blocked,
          old_code: old_code?(entry.module),
          blocked_reason: :old_code_in_use,
          lingering_pids: lingering_pids
      }
    end)
  end

  def mark_apply_error(id, reason) do
    update(id, fn entry ->
      %{entry | blocked_reason: reason}
    end)
  end

  defp update(id, fun) do
    ensure_started()
    entry = fetch(id) || %Entry{id: id}
    updated = fun.(entry)
    :ets.insert(@table, {id, updated})
    updated
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
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

  defp old_code?(nil), do: false
  defp old_code?(module) when is_atom(module), do: :erlang.check_old_code(module)
end
