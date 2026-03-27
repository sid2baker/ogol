defmodule Ogol.HMI.SurfaceDraftStore do
  @moduledoc false

  use GenServer

  alias Ogol.HMI.Surface
  alias Ogol.HMI.SurfaceDraftStore.Draft
  alias Ogol.HMI.SurfacePrinter
  alias Ogol.HMI.Surfaces.OperationsAlarmFocus
  alias Ogol.HMI.Surfaces.OperationsOverview
  alias Ogol.HMI.Surfaces.OperationsStation

  @table :ogol_hmi_surface_drafts
  @seed_modules [OperationsOverview, OperationsAlarmFocus, OperationsStation]

  defmodule Draft do
    @moduledoc false

    @type t :: %__MODULE__{
            surface_id: atom(),
            source: String.t(),
            source_module: module(),
            saved_at: DateTime.t() | nil,
            published_versions: %{
              optional(String.t()) => %{definition: Surface.t(), runtime: Surface.Runtime.t()}
            },
            compiled_definition: Surface.t() | nil,
            compiled_runtime: Surface.Runtime.t() | nil,
            compiled_version: String.t() | nil,
            compiled_at: DateTime.t() | nil,
            deployed_definition: Surface.t() | nil,
            deployed_runtime: Surface.Runtime.t() | nil,
            deployed_version: String.t() | nil,
            deployed_at: DateTime.t() | nil
          }

    defstruct [
      :surface_id,
      :source,
      :source_module,
      :saved_at,
      :compiled_definition,
      :compiled_runtime,
      :compiled_version,
      :compiled_at,
      :deployed_definition,
      :deployed_runtime,
      :deployed_version,
      :deployed_at,
      published_versions: %{}
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    :ets.delete_all_objects(@table)
    seed_defaults()
  end

  def list_drafts do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.surface_id)
  end

  def fetch(surface_id) when is_atom(surface_id) or is_binary(surface_id) do
    @table
    |> :ets.tab2list()
    |> Enum.find_value(fn {stored_id, %Draft{} = draft} ->
      if to_string(stored_id) == to_string(surface_id), do: draft
    end)
  end

  def published_versions(%Draft{} = draft) do
    draft.published_versions
    |> Map.keys()
    |> Enum.sort_by(&version_sort_key/1, :desc)
  end

  def save_source(surface_id, source) when is_binary(source) do
    now = DateTime.utc_now()

    update(surface_id, fn draft ->
      %{draft | source: source, saved_at: now}
    end)
  end

  def compile(surface_id, _source, %Surface{} = definition, %Surface.Runtime{} = runtime) do
    now = DateTime.utc_now()

    update(surface_id, fn draft ->
      version = next_version(draft.compiled_version)

      %{
        draft
        | compiled_definition: definition,
          compiled_runtime: %{runtime | module: nil},
          compiled_version: version,
          compiled_at: now
      }
    end)
  end

  def deploy(surface_id) do
    now = DateTime.utc_now()

    update(surface_id, fn draft ->
      if draft.compiled_runtime do
        published_versions =
          Map.put(draft.published_versions || %{}, draft.compiled_version, %{
            definition: draft.compiled_definition,
            runtime: draft.compiled_runtime
          })

        %{
          draft
          | published_versions: published_versions,
            deployed_definition: draft.compiled_definition,
            deployed_runtime: draft.compiled_runtime,
            deployed_version: draft.compiled_version,
            deployed_at: now
        }
      else
        draft
      end
    end)
  end

  def fetch_deployed_runtime(surface_id, version \\ nil)

  def fetch_deployed_runtime(surface_id, version) do
    case fetch(surface_id) do
      %Draft{} = draft ->
        version = version || draft.deployed_version

        case Map.get(draft.published_versions || %{}, version) do
          %{runtime: %Surface.Runtime{} = runtime} ->
            {:ok, runtime, version}

          nil ->
            fallback_deployed_runtime(draft, version)
        end

      _ ->
        :error
    end
  end

  defp fallback_deployed_runtime(
         %Draft{
           deployed_runtime: %Surface.Runtime{} = runtime,
           deployed_version: deployed_version
         },
         version
       )
       when is_nil(version) or version == deployed_version do
    {:ok, runtime, deployed_version}
  end

  defp fallback_deployed_runtime(_draft, _version), do: :error

  defp build_seeded_draft(module) do
    definition = Surface.definition(module)
    runtime = %{Surface.runtime(module) | module: nil}
    source_module = SurfacePrinter.canonical_module(definition)
    source = SurfacePrinter.print(definition, module: source_module)

    %Draft{
      surface_id: definition.id,
      source: source,
      source_module: source_module,
      saved_at: DateTime.utc_now(),
      published_versions: %{"current" => %{definition: definition, runtime: runtime}},
      compiled_definition: definition,
      compiled_runtime: runtime,
      compiled_version: "current",
      compiled_at: DateTime.utc_now(),
      deployed_definition: definition,
      deployed_runtime: runtime,
      deployed_version: "current",
      deployed_at: DateTime.utc_now()
    }
  end

  defp seed_defaults do
    Enum.each(@seed_modules, fn module ->
      draft = build_seeded_draft(module)
      :ets.insert(@table, {draft.surface_id, draft})
    end)

    :ok
  end

  defp seed_draft_for(surface_id) do
    module =
      Enum.find(@seed_modules, fn candidate ->
        to_string(Surface.definition(candidate).id) == to_string(surface_id)
      end)

    if module do
      build_seeded_draft(module)
    else
      raise ArgumentError, "unknown HMI surface draft #{inspect(surface_id)}"
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    seed_defaults()
    {:ok, %{}}
  end

  defp update(surface_id, fun) do
    draft = fetch(surface_id) || seed_draft_for(surface_id)
    updated = fun.(draft)
    :ets.insert(@table, {updated.surface_id, updated})
    updated
  end

  defp next_version(nil), do: "r1"
  defp next_version("current"), do: "r1"

  defp next_version("r" <> rest) do
    case Integer.parse(rest) do
      {value, ""} -> "r#{value + 1}"
      _ -> "r1"
    end
  end

  defp next_version(_other), do: "r1"

  defp version_sort_key("current"), do: {0, 0}

  defp version_sort_key("r" <> rest) do
    case Integer.parse(rest) do
      {value, ""} -> {1, value}
      _ -> {0, 0}
    end
  end

  defp version_sort_key(_other), do: {0, 0}
end
