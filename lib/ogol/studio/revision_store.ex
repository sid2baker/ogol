defmodule Ogol.Studio.RevisionStore do
  @moduledoc false

  use GenServer

  alias Ogol.Studio.Build
  alias Ogol.Studio.Bundle

  @table :ogol_studio_revisions
  @revisions_key :revisions

  defmodule Revision do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            app_id: String.t(),
            title: String.t() | nil,
            source: String.t(),
            source_digest: String.t(),
            deployed_at: DateTime.t()
          }

    defstruct [:id, :app_id, :title, :source, :source_digest, :deployed_at]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    seed_defaults()
    :ok
  end

  def list_revisions do
    ensure_started()
    fetch(@revisions_key) || []
  end

  def fetch_revision(id) when is_binary(id) do
    list_revisions()
    |> Enum.find(&(&1.id == id))
  end

  def deploy_current(opts \\ []) do
    ensure_started()

    app_id = Keyword.get(opts, :app_id, "ogol_bundle")
    title = Keyword.get(opts, :title)
    revision_id = next_revision_id(list_revisions())
    deployed_at = DateTime.utc_now()

    with {:ok, source} <-
           Bundle.export_current(
             app_id: app_id,
             title: title,
             revision: revision_id,
             exported_at: DateTime.to_iso8601(deployed_at)
           ) do
      revision = %Revision{
        id: revision_id,
        app_id: app_id,
        title: title,
        source: source,
        source_digest: Build.digest(source),
        deployed_at: deployed_at
      }

      put(@revisions_key, [revision | list_revisions()])

      {:ok, revision}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    seed_defaults()
    {:ok, %{}}
  end

  defp next_revision_id(revisions) do
    revisions
    |> Enum.map(&revision_number/1)
    |> Enum.max(fn -> 0 end)
    |> then(&"r#{&1 + 1}")
  end

  defp revision_number(%Revision{id: "r" <> rest}) do
    case Integer.parse(rest) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp revision_number(_other), do: 0

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start #{inspect(__MODULE__)}: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end

  defp seed_defaults do
    :ets.insert(@table, {@revisions_key, []})
  end

  defp fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  end
end
