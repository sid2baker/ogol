defmodule Ogol.Studio.RevisionFile do
  @moduledoc false

  alias Ogol.Driver.Parser, as: DriverParser
  alias Ogol.Driver.Source, as: DriverSource
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Studio.Build
  alias Ogol.Studio.WorkspaceStore.DriverDraft, as: DriverDraft
  alias Ogol.Studio.WorkspaceStore.MachineDraft, as: MachineDraft
  alias Ogol.Studio.WorkspaceStore.TopologyDraft, as: TopologyDraft
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Studio.WorkspaceStore.SequenceDraft, as: SequenceDraft
  alias Ogol.Topology.Source, as: TopologySource

  alias Ogol.Hardware.Config, as: HardwareConfig
  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias Ogol.HMI.Surface.Compiler, as: SurfaceCompiler
  alias Ogol.HMI.Surface.RuntimeStore, as: SurfaceRuntimeStore
  alias Ogol.Studio.WorkspaceStore.HmiSurfaceDraft

  @revision_file_kind :ogol_revision
  @revision_file_format 2
  @source_backed_kinds [:driver, :machine, :sequence, :topology, :hardware_config, :hmi_surface]

  defmodule Artifact do
    @moduledoc false

    @type t :: %__MODULE__{
            kind: atom(),
            id: String.t(),
            module: module(),
            source: String.t(),
            digest: String.t(),
            sync_state: :synced | :partial | :unsupported,
            model: map() | nil,
            diagnostics: [term()],
            digest_match?: boolean(),
            title: String.t() | nil
          }

    defstruct [
      :kind,
      :id,
      :module,
      :source,
      :digest,
      :sync_state,
      :model,
      :title,
      diagnostics: [],
      digest_match?: true
    ]
  end

  @type t :: %__MODULE__{
          app_id: String.t(),
          title: String.t() | nil,
          format: pos_integer(),
          manifest_module: module(),
          revision: String.t(),
          exported_at: String.t() | nil,
          artifacts: [Artifact.t()],
          metadata: map() | nil,
          source: String.t() | nil,
          warnings: [term()]
        }

  defstruct [
    :app_id,
    :title,
    :manifest_module,
    :revision,
    :exported_at,
    :metadata,
    :source,
    warnings: [],
    format: @revision_file_format,
    artifacts: []
  ]

  @spec export_current(keyword()) :: {:ok, String.t()} | {:error, term()}
  def export_current(opts \\ []) do
    revision = Keyword.get(opts, :revision, "draft")
    app_id = Keyword.get(opts, :app_id, "ogol")

    with {:ok, artifacts} <- current_artifacts() do
      revision_file = %__MODULE__{
        app_id: app_id,
        title: opts[:title],
        format: @revision_file_format,
        revision: revision,
        exported_at: opts[:exported_at],
        manifest_module: opts[:manifest_module] || manifest_module_for_app_id(app_id, revision),
        metadata: opts[:metadata],
        artifacts: Enum.sort_by(artifacts, &artifact_sort_key/1)
      }

      {:ok, render(revision_file)}
    end
  end

  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = revision_file) do
    manifest_source(revision_file) <>
      case revision_file.artifacts do
        [] ->
          ""

        artifacts ->
          "\n\n" <>
            Enum.map_join(artifacts, "\n\n", fn artifact ->
              artifact.source
            end)
      end
  end

  @spec artifacts(t(), atom()) :: [Artifact.t()]
  def artifacts(%__MODULE__{artifacts: artifacts}, kind) when is_atom(kind) do
    Enum.filter(artifacts, &(&1.kind == kind))
  end

  @spec loaded_inventory(t()) :: [WorkspaceStore.LoadedRevision.inventory_item()]
  def loaded_inventory(%__MODULE__{artifacts: artifacts}) do
    source_backed_inventory(artifacts)
  end

  @spec artifact(t(), atom(), String.t() | atom()) :: Artifact.t() | nil
  def artifact(%__MODULE__{} = revision_file, kind, id) when is_atom(kind) do
    normalized_id = to_string(id)
    Enum.find(artifacts(revision_file, kind), &(&1.id == normalized_id))
  end

  @spec import(String.t()) :: {:ok, t()} | {:error, term()}
  def import(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, module_sources} <- extract_module_sources(source, ast),
         {:ok, manifest_module, manifest} <- extract_manifest(module_sources),
         {:ok, artifacts, warnings} <- import_artifacts(module_sources, manifest_module, manifest) do
      {:ok,
       %__MODULE__{
         app_id: manifest.app_id,
         title: manifest[:title],
         format: manifest.format,
         manifest_module: manifest_module,
         revision: manifest.revision,
         exported_at: manifest[:exported_at],
         artifacts: artifacts,
         metadata: manifest[:metadata],
         source: source,
         warnings: warnings
       }}
    end
  end

  @type load_mode :: :initial | :compatible_reload | :forced_reload

  @spec load_into_workspace(String.t(), keyword()) ::
          {:ok, t(), %{mode: load_mode()}} | {:error, term()}
  def load_into_workspace(source, opts \\ []) when is_binary(source) do
    with {:ok, %__MODULE__{} = revision_file} <- __MODULE__.import(source),
         {:ok, mode} <- load_mode(revision_file, Keyword.get(opts, :force, false)),
         :ok <- load_revision_into_workspace(revision_file, mode) do
      WorkspaceStore.put_loaded_revision(
        revision_file.app_id,
        revision_file.revision,
        source_backed_inventory(revision_file.artifacts)
      )

      {:ok, revision_file, %{mode: mode}}
    end
  end

  defp load_mode(%__MODULE__{} = revision_file, force?) do
    current_inventory = WorkspaceStore.loaded_inventory()
    incoming_inventory = source_backed_inventory(revision_file.artifacts)

    cond do
      current_inventory == [] ->
        {:ok, :initial}

      compatible_inventory?(current_inventory, incoming_inventory) ->
        {:ok, :compatible_reload}

      force? ->
        {:ok, :forced_reload}

      true ->
        {:error, {:structural_mismatch, inventory_diff(current_inventory, incoming_inventory)}}
    end
  end

  defp load_revision_into_workspace(%__MODULE__{artifacts: artifacts}, :compatible_reload) do
    sync_current_draft(artifacts)
  end

  defp load_revision_into_workspace(%__MODULE__{artifacts: artifacts}, _mode) do
    replace_current_draft(artifacts)
  end

  defp source_backed_inventory(artifacts) do
    artifacts
    |> Enum.filter(&source_backed_artifact?/1)
    |> Enum.map(fn %Artifact{} = artifact ->
      %{kind: artifact.kind, id: artifact.id, module: artifact.module}
    end)
    |> Enum.sort_by(fn %{kind: kind, id: id} -> {kind, id} end)
  end

  defp compatible_inventory?(current_inventory, incoming_inventory) do
    inventory_diff(current_inventory, incoming_inventory) == %{
      added: [],
      removed: [],
      changed: []
    }
  end

  defp inventory_diff(current_inventory, incoming_inventory) do
    current_by_key = Map.new(current_inventory, &{{&1.kind, &1.id}, &1})
    incoming_by_key = Map.new(incoming_inventory, &{{&1.kind, &1.id}, &1})

    current_keys = Map.keys(current_by_key) |> MapSet.new()
    incoming_keys = Map.keys(incoming_by_key) |> MapSet.new()

    added =
      incoming_keys
      |> MapSet.difference(current_keys)
      |> Enum.map(&Map.fetch!(incoming_by_key, &1))
      |> Enum.sort_by(fn %{kind: kind, id: id} -> {kind, id} end)

    removed =
      current_keys
      |> MapSet.difference(incoming_keys)
      |> Enum.map(&Map.fetch!(current_by_key, &1))
      |> Enum.sort_by(fn %{kind: kind, id: id} -> {kind, id} end)

    changed =
      current_keys
      |> MapSet.intersection(incoming_keys)
      |> Enum.reduce([], fn key, acc ->
        current = Map.fetch!(current_by_key, key)
        incoming = Map.fetch!(incoming_by_key, key)

        if current.module == incoming.module do
          acc
        else
          [
            %{
              kind: current.kind,
              id: current.id,
              current_module: current.module,
              incoming_module: incoming.module
            }
            | acc
          ]
        end
      end)
      |> Enum.sort_by(fn %{kind: kind, id: id} -> {kind, id} end)

    %{added: added, removed: removed, changed: changed}
  end

  defp source_backed_artifact?(%Artifact{kind: kind}), do: kind in @source_backed_kinds

  defp current_artifacts do
    with {:ok, driver_artifacts} <- driver_artifacts_from_store(),
         {:ok, machine_artifacts} <- machine_artifacts_from_store(),
         {:ok, sequence_artifacts} <- sequence_artifacts_from_store(),
         {:ok, topology_artifacts} <- topology_artifacts_from_store(),
         {:ok, surface_artifacts} <- hmi_surface_artifacts_from_store(),
         {:ok, hardware_artifacts} <- hardware_config_artifacts_from_store() do
      {:ok,
       driver_artifacts ++
         machine_artifacts ++
         sequence_artifacts ++
         topology_artifacts ++
         surface_artifacts ++
         hardware_artifacts}
    end
  end

  defp driver_artifacts_from_store do
    WorkspaceStore.list_drivers()
    |> Enum.reduce_while({:ok, []}, fn draft, {:ok, artifacts} ->
      case driver_artifact_from_draft(draft) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | artifacts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end

  defp hmi_surface_artifacts_from_store do
    WorkspaceStore.list_hmi_surfaces()
    |> Enum.map(&hmi_surface_artifact_from_draft/1)
    |> then(&{:ok, &1})
  end

  defp machine_artifacts_from_store do
    WorkspaceStore.list_machines()
    |> Enum.reduce_while({:ok, []}, fn draft, {:ok, artifacts} ->
      case machine_artifact_from_draft(draft) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | artifacts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end

  defp topology_artifacts_from_store do
    WorkspaceStore.list_topologies()
    |> Enum.reduce_while({:ok, []}, fn draft, {:ok, artifacts} ->
      case topology_artifact_from_draft(draft) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | artifacts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end

  defp sequence_artifacts_from_store do
    WorkspaceStore.list_sequences()
    |> Enum.reduce_while({:ok, []}, fn draft, {:ok, artifacts} ->
      case sequence_artifact_from_draft(draft) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | artifacts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end

  defp hardware_config_artifacts_from_store do
    case WorkspaceStore.current_hardware_config() do
      %HardwareConfig{} = config ->
        if exportable_hardware_config?(config) do
          {:ok, [hardware_config_artifact(config)]}
        else
          {:ok, []}
        end

      _other ->
        {:ok, []}
    end
  end

  defp driver_artifact_from_draft(draft) do
    source = normalize_module_source(draft.source)

    with {:ok, module} <- driver_module_from_draft(draft, source) do
      {:ok,
       %Artifact{
         kind: :driver,
         id: draft.id,
         module: module,
         source: source,
         digest: Build.digest(source),
         sync_state: draft.sync_state,
         model: draft.model,
         diagnostics: draft.sync_diagnostics,
         title: draft.model && draft.model.label
       }}
    end
  end

  defp driver_module_from_draft(draft, source) do
    case DriverParser.module_from_source(source) do
      {:ok, module} ->
        {:ok, module}

      {:error, :module_not_found} ->
        case draft.model do
          %{module_name: module_name} -> {:ok, DriverSource.module_from_name!(module_name)}
          _ -> {:error, {:artifact_module_not_found, :driver, draft.id}}
        end
    end
  end

  defp hmi_surface_artifact_from_draft(draft) do
    source = normalize_module_source(draft.source)

    %Artifact{
      kind: :hmi_surface,
      id: draft.id,
      module: draft.source_module,
      source: source,
      digest: Build.digest(source),
      sync_state: draft.sync_state,
      model: draft.model,
      diagnostics: draft.sync_diagnostics,
      title: extract_surface_title(source)
    }
  end

  defp machine_artifact_from_draft(draft) do
    source = normalize_module_source(draft.source)

    with {:ok, module} <- machine_module_from_draft(draft, source) do
      {:ok,
       %Artifact{
         kind: :machine,
         id: draft.id,
         module: module,
         source: source,
         digest: Build.digest(source),
         sync_state: draft.sync_state,
         model: draft.model,
         diagnostics: draft.sync_diagnostics,
         title: draft.model && draft.model.meaning
       }}
    end
  end

  defp machine_module_from_draft(draft, source) do
    case MachineSource.module_from_source(source) do
      {:ok, module} ->
        {:ok, module}

      {:error, :module_not_found} ->
        case draft.model do
          %{module_name: module_name} -> {:ok, MachineSource.module_from_name!(module_name)}
          _ -> {:error, {:artifact_module_not_found, :machine, draft.id}}
        end
    end
  end

  defp topology_artifact_from_draft(draft) do
    source = normalize_module_source(draft.source)

    with {:ok, module} <- topology_module_from_draft(draft, source) do
      {:ok,
       %Artifact{
         kind: :topology,
         id: draft.id,
         module: module,
         source: source,
         digest: Build.digest(source),
         sync_state: draft.sync_state,
         model: draft.model,
         diagnostics: draft.sync_diagnostics,
         title: draft.model && draft.model.meaning
       }}
    end
  end

  defp sequence_artifact_from_draft(draft) do
    source = normalize_module_source(draft.source)

    with {:ok, module} <- sequence_module_from_draft(draft, source) do
      {:ok,
       %Artifact{
         kind: :sequence,
         id: draft.id,
         module: module,
         source: source,
         digest: Build.digest(source),
         sync_state: draft.sync_state,
         model: draft.model,
         diagnostics: draft.sync_diagnostics,
         title: draft.model && draft.model.meaning
       }}
    end
  end

  defp sequence_module_from_draft(draft, source) do
    case SequenceSource.module_from_source(source) do
      {:ok, module} ->
        {:ok, module}

      {:error, :module_not_found} ->
        case draft.model do
          %{module_name: module_name} -> {:ok, SequenceSource.module_from_name!(module_name)}
          _ -> {:error, {:artifact_module_not_found, :sequence, draft.id}}
        end
    end
  end

  defp topology_module_from_draft(draft, source) do
    case TopologySource.module_from_source(source) do
      {:ok, module} ->
        {:ok, module}

      {:error, :module_not_found} ->
        case draft.model do
          %{module_name: module_name} -> {:ok, TopologySource.module_from_name!(module_name)}
          _ -> {:error, {:artifact_module_not_found, :topology, draft.id}}
        end
    end
  end

  defp hardware_config_artifact(config) do
    source =
      config
      |> HardwareConfigSource.to_source()
      |> normalize_module_source()

    %Artifact{
      kind: :hardware_config,
      id: WorkspaceStore.hardware_config_entry_id(),
      module: HardwareConfigSource.canonical_module(),
      source: source,
      digest: Build.digest(source),
      sync_state: :synced,
      model: config,
      diagnostics: [],
      title: config.label
    }
  end

  defp manifest_source(%__MODULE__{} = revision_file) do
    manifest_ast =
      quote do
        defmodule unquote(revision_file.manifest_module) do
          @revision unquote(manifest_map_ast(revision_file))
          def manifest, do: @revision
        end
      end

    manifest_ast
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  defp manifest_map_ast(%__MODULE__{} = revision_file) do
    map_ast_from_pairs(
      [
        {:kind, @revision_file_kind},
        {:format, revision_file.format},
        {:app_id, revision_file.app_id},
        {:revision, revision_file.revision},
        optional_pair(:title, revision_file.title),
        optional_pair(:exported_at, revision_file.exported_at),
        {:sources, {:__raw_ast__, Enum.map(revision_file.artifacts, &artifact_entry_ast/1)}},
        optional_pair(:metadata, revision_file.metadata)
      ]
      |> Enum.reject(&is_nil/1)
    )
  end

  defp artifact_entry_ast(%Artifact{} = artifact) do
    map_ast_from_pairs(
      [
        {:kind, artifact.kind},
        {:id, artifact.id},
        {:module, artifact.module},
        {:digest, artifact.digest},
        optional_pair(:title, artifact.title)
      ]
      |> Enum.reject(&is_nil/1)
    )
  end

  defp optional_pair(_key, nil), do: nil
  defp optional_pair(key, value), do: {key, value}

  defp map_ast_from_pairs(pairs) do
    {:%{}, [],
     Enum.map(pairs, fn {key, value} -> {literal_to_ast(key), literal_to_ast(value)} end)}
  end

  defp literal_to_ast(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
    |> Enum.map(fn {key, item} -> {literal_to_ast(key), literal_to_ast(item)} end)
    |> then(&{:%{}, [], &1})
  end

  defp literal_to_ast({:__raw_ast__, ast}), do: ast

  defp literal_to_ast(value) when is_list(value), do: Enum.map(value, &literal_to_ast/1)

  defp literal_to_ast(value) when is_tuple(value),
    do: {:{}, [], Enum.map(Tuple.to_list(value), &literal_to_ast/1)}

  defp literal_to_ast(value) when is_atom(value) do
    if module_alias?(value) do
      alias_ast(value)
    else
      Macro.escape(value)
    end
  end

  defp literal_to_ast(value), do: Macro.escape(value)

  defp extract_module_sources(source, ast) do
    forms = top_level_forms(ast)

    if Enum.all?(forms, &match?({:defmodule, _, _}, &1)) do
      module_sources =
        forms
        |> Enum.map(&module_source_entry(source, &1))
        |> Enum.sort_by(fn %{start_line: line} -> line end)

      {:ok, module_sources}
    else
      {:error, :non_module_top_level_form}
    end
  end

  defp module_source_entry(source, {:defmodule, meta, [module_ast, _body]} = form) do
    %{
      module: module_from_ast!(module_ast),
      ast: form,
      source: slice_module_source(source, meta),
      start_line: meta[:line]
    }
  end

  defp slice_module_source(source, meta) do
    lines = String.split(source, "\n", trim: false)
    start_line = meta[:line] || 1
    end_line = get_in(meta, [:end, :line]) || start_line

    lines
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.join("\n")
  end

  defp extract_manifest(module_sources) do
    manifests =
      Enum.filter(module_sources, fn %{ast: form} ->
        match?({:ok, _}, manifest_from_module_ast(form))
      end)

    case manifests do
      [%{module: manifest_module, ast: form}] ->
        with {:ok, manifest} <- manifest_from_module_ast(form),
             {:ok, manifest} <- validate_manifest(manifest) do
          {:ok, manifest_module, manifest}
        end

      [] ->
        {:error, :missing_manifest}

      _ ->
        {:error, :multiple_manifests}
    end
  end

  defp manifest_from_module_ast({:defmodule, _meta, [_module_ast, [do: body]]}) do
    forms = top_level_forms(body)
    revision_attr_ast = Enum.find_value(forms, &revision_attribute_ast/1)

    case Enum.find_value(forms, &manifest_body_ast/1) do
      nil ->
        {:error, :missing_manifest_function}

      body_ast ->
        body_ast
        |> resolve_manifest_body(revision_attr_ast)
        |> literal_from_ast()
    end
  end

  defp manifest_from_module_ast(_other), do: {:error, :unsupported_manifest}

  defp revision_attribute_ast({:@, _, [{:revision, _, [value_ast]}]}), do: value_ast
  defp revision_attribute_ast(_other), do: nil

  defp manifest_body_ast({:def, _, [{:manifest, _, args}, [do: {:__block__, _, [body_ast]}]]})
       when args in [nil, []],
       do: body_ast

  defp manifest_body_ast({:def, _, [{:manifest, _, args}, [do: body_ast]]})
       when args in [nil, []],
       do: body_ast

  defp manifest_body_ast(_other), do: nil

  defp resolve_manifest_body({:@, _, [{:revision, _, _}]}, revision_attr_ast)
       when not is_nil(revision_attr_ast),
       do: revision_attr_ast

  defp resolve_manifest_body(body_ast, _revision_attr_ast), do: body_ast

  defp validate_manifest(manifest) when is_map(manifest) do
    with :ok <- validate_revision_file_kind(manifest),
         {:ok, format} <- fetch_supported_format(manifest),
         {:ok, app_id} <- fetch_string_key(manifest, :app_id),
         {:ok, revision} <- fetch_string_key(manifest, :revision),
         {:ok, sources} <- fetch_source_entries(manifest),
         {:ok, title} <- fetch_optional_string_key(manifest, :title),
         {:ok, exported_at} <- fetch_optional_string_key(manifest, :exported_at),
         {:ok, metadata} <- fetch_optional_map_key(manifest, :metadata) do
      {:ok,
       %{
         kind: @revision_file_kind,
         format: format,
         app_id: app_id,
         revision: revision,
         title: title,
         exported_at: exported_at,
         sources: sources,
         metadata: metadata
       }}
    end
  end

  defp validate_manifest(_other), do: {:error, {:invalid_manifest, :non_map}}

  defp validate_revision_file_kind(manifest) do
    case fetch_optional(manifest, :kind, nil) do
      @revision_file_kind -> :ok
      other -> {:error, {:invalid_manifest, {:kind, other}}}
    end
  end

  defp import_artifacts(module_sources, manifest_module, manifest) do
    modules_by_name =
      module_sources
      |> Enum.reject(&(&1.module == manifest_module))
      |> Map.new(fn %{module: module} = entry -> {module, entry} end)

    warnings = unexpected_module_warnings(modules_by_name, manifest.sources)

    with {:ok, imported} <- do_import_artifacts(modules_by_name, manifest.sources) do
      {:ok, Enum.sort_by(imported, &artifact_sort_key/1), warnings}
    end
  end

  defp unexpected_module_warnings(modules_by_name, manifest_sources) do
    expected_modules = MapSet.new(Enum.map(manifest_sources, &fetch_optional(&1, :module, nil)))

    modules_by_name
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(expected_modules, &1))
    |> Enum.sort()
    |> Enum.map(&{:ignored_module, &1})
  end

  defp do_import_artifacts(modules_by_name, manifest_sources) do
    Enum.reduce_while(manifest_sources, {:ok, []}, fn entry, {:ok, imported} ->
      module = fetch_optional(entry, :module, nil)

      case Map.fetch(modules_by_name, module) do
        {:ok, %{source: source}} ->
          artifact = import_artifact_entry(entry, source)
          {:cont, {:ok, [artifact | imported]}}

        :error ->
          {:halt, {:error, {:missing_artifact_module, module}}}
      end
    end)
    |> case do
      {:ok, imported} -> {:ok, Enum.reverse(imported)}
      error -> error
    end
  end

  defp import_artifact_entry(entry, source) do
    kind = fetch_optional(entry, :kind, :unknown)
    actual_digest = Build.digest(source)
    expected_digest = fetch_optional(entry, :digest, nil)

    base = %Artifact{
      kind: kind,
      id: fetch_optional(entry, :id, "unknown") |> to_string(),
      module: fetch_optional(entry, :module, nil),
      source: source,
      digest: actual_digest,
      title: fetch_optional(entry, :title, nil),
      digest_match?: expected_digest in [nil, actual_digest]
    }

    case classify_artifact(kind, source) do
      {:ok, model} ->
        %{base | id: canonical_artifact_id(kind, base.id), sync_state: :synced, model: model}

      {:partial, model, diagnostics} ->
        %{
          base
          | id: canonical_artifact_id(kind, base.id),
            sync_state: :partial,
            model: model,
            diagnostics: diagnostics
        }

      {:unsupported, diagnostics} ->
        %{
          base
          | id: canonical_artifact_id(kind, base.id),
            sync_state: :unsupported,
            diagnostics: diagnostics
        }
    end
  end

  defp classify_artifact(:driver, source) do
    case DriverSource.from_source(source) do
      {:ok, model} ->
        {:ok, model}

      {:partial, model, diagnostics} ->
        {:partial, model, diagnostics}

      :unsupported ->
        {:unsupported, ["driver source could not be recovered into the managed Studio subset"]}
    end
  end

  defp classify_artifact(:machine, source) do
    case MachineSource.from_source(source) do
      {:ok, model} ->
        {:ok, model}

      {:error, diagnostics} ->
        {:unsupported, diagnostics}
    end
  end

  defp classify_artifact(:sequence, source) do
    case SequenceSource.from_source(source) do
      {:ok, model} ->
        {:ok, model}

      {:error, diagnostics} ->
        {:unsupported, diagnostics}
    end
  end

  defp classify_artifact(:topology, source) do
    case TopologySource.from_source(source) do
      {:ok, model} ->
        {:ok, model}

      {:error, diagnostics} ->
        {:unsupported, diagnostics}
    end
  end

  defp classify_artifact(:hardware_config, source) do
    case HardwareConfigSource.from_source(source) do
      {:ok, config} ->
        {:ok, config}

      :unsupported ->
        {:unsupported,
         ["hardware config source could not be recovered into the managed Studio subset"]}
    end
  end

  defp classify_artifact(:hmi_surface, source) do
    case SurfaceCompiler.analyze(source) do
      %{classification: :visual, definition: definition} ->
        {:ok, definition}

      %{diagnostics: diagnostics} ->
        {:unsupported, diagnostics}
    end
  end

  defp classify_artifact(kind, _source) do
    {:unsupported,
     ["No Studio revision import handler is implemented for kind #{inspect(kind)} yet."]}
  end

  defp replace_current_draft(artifacts) do
    artifacts_by_kind = Enum.group_by(artifacts, & &1.kind)

    WorkspaceStore.replace_drivers(
      Enum.map(Map.get(artifacts_by_kind, :driver, []), &driver_draft_from_artifact/1)
    )

    WorkspaceStore.replace_machines(
      Enum.map(Map.get(artifacts_by_kind, :machine, []), &machine_draft_from_artifact/1)
    )

    WorkspaceStore.replace_sequences(
      Enum.map(Map.get(artifacts_by_kind, :sequence, []), &sequence_draft_from_artifact/1)
    )

    WorkspaceStore.replace_topologies(
      Enum.map(
        Map.get(artifacts_by_kind, :topology, []),
        &topology_draft_from_artifact/1
      )
    )

    WorkspaceStore.replace_hmi_surfaces(
      Enum.map(Map.get(artifacts_by_kind, :hmi_surface, []), &hmi_surface_draft_from_artifact/1)
    )

    SurfaceRuntimeStore.reset()

    replace_hardware_config_artifacts(Map.get(artifacts_by_kind, :hardware_config, []))

    :ok
  end

  defp sync_current_draft(artifacts) do
    artifacts_by_kind = Enum.group_by(artifacts, & &1.kind)

    Enum.each(Map.get(artifacts_by_kind, :driver, []), fn %Artifact{} = artifact ->
      WorkspaceStore.save_driver_source(
        artifact.id,
        artifact.source,
        artifact.model,
        artifact.sync_state,
        List.wrap(artifact.diagnostics)
      )
    end)

    Enum.each(Map.get(artifacts_by_kind, :machine, []), fn %Artifact{} = artifact ->
      WorkspaceStore.save_machine_source(
        artifact.id,
        artifact.source,
        artifact.model,
        artifact.sync_state,
        List.wrap(artifact.diagnostics)
      )
    end)

    Enum.each(Map.get(artifacts_by_kind, :sequence, []), fn %Artifact{} = artifact ->
      WorkspaceStore.save_sequence_source(
        artifact.id,
        artifact.source,
        artifact.model,
        artifact.sync_state,
        List.wrap(artifact.diagnostics)
      )
    end)

    Enum.each(Map.get(artifacts_by_kind, :topology, []), fn %Artifact{} = artifact ->
      WorkspaceStore.save_topology_source(
        artifact.id,
        artifact.source,
        artifact.model,
        artifact.sync_state,
        List.wrap(artifact.diagnostics)
      )
    end)

    Enum.each(Map.get(artifacts_by_kind, :hmi_surface, []), fn %Artifact{} = artifact ->
      WorkspaceStore.save_hmi_surface_source(
        artifact.id,
        artifact.source,
        artifact.module,
        artifact.model,
        artifact.sync_state,
        List.wrap(artifact.diagnostics)
      )
    end)

    sync_hardware_config_artifacts(Map.get(artifacts_by_kind, :hardware_config, []))

    :ok
  end

  defp driver_draft_from_artifact(%Artifact{} = artifact) do
    %DriverDraft{
      id: artifact.id,
      source: artifact.source,
      model: artifact.model,
      sync_state: artifact.sync_state,
      sync_diagnostics: List.wrap(artifact.diagnostics)
    }
  end

  defp machine_draft_from_artifact(%Artifact{} = artifact) do
    %MachineDraft{
      id: artifact.id,
      source: artifact.source,
      model: artifact.model,
      sync_state: artifact.sync_state,
      sync_diagnostics: List.wrap(artifact.diagnostics)
    }
  end

  defp topology_draft_from_artifact(%Artifact{} = artifact) do
    %TopologyDraft{
      id: artifact.id,
      source: artifact.source,
      model: artifact.model,
      sync_state: artifact.sync_state,
      sync_diagnostics: List.wrap(artifact.diagnostics)
    }
  end

  defp sequence_draft_from_artifact(%Artifact{} = artifact) do
    %SequenceDraft{
      id: artifact.id,
      source: artifact.source,
      model: artifact.model,
      sync_state: artifact.sync_state,
      sync_diagnostics: List.wrap(artifact.diagnostics)
    }
  end

  defp hardware_config_draft_from_artifact(%Artifact{} = artifact) do
    %WorkspaceStore.HardwareConfigDraft{
      id: WorkspaceStore.hardware_config_entry_id(),
      source: artifact.source,
      model: artifact.model,
      sync_state: artifact.sync_state,
      sync_diagnostics: List.wrap(artifact.diagnostics)
    }
  end

  defp hmi_surface_draft_from_artifact(%Artifact{} = artifact) do
    %HmiSurfaceDraft{
      id: artifact.id,
      source: artifact.source,
      source_module: artifact.module,
      model: artifact.model,
      sync_state: artifact.sync_state,
      sync_diagnostics: List.wrap(artifact.diagnostics)
    }
  end

  defp replace_hardware_config_artifacts([%Artifact{kind: :hardware_config} = artifact]) do
    WorkspaceStore.replace_hardware_configs([
      hardware_config_draft_from_artifact(artifact)
    ])
  end

  defp replace_hardware_config_artifacts(_artifacts) do
    WorkspaceStore.replace_hardware_configs([])
  end

  defp sync_hardware_config_artifacts([%Artifact{kind: :hardware_config} = artifact]) do
    WorkspaceStore.save_hardware_config_source(
      artifact.source,
      artifact.model,
      artifact.sync_state,
      List.wrap(artifact.diagnostics)
    )
  end

  defp sync_hardware_config_artifacts(_artifacts), do: :ok

  defp top_level_forms({:__block__, _, forms}), do: forms
  defp top_level_forms(form), do: [form]

  defp module_from_ast!({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_from_ast!(atom) when is_atom(atom), do: atom

  defp module_alias?(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.starts_with?("Elixir.")
  end

  defp alias_ast(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
    |> then(&{:__aliases__, [alias: false], &1})
  end

  defp literal_from_ast({:%{}, _, entries}) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key_ast, value_ast}, {:ok, acc} ->
      with {:ok, key} <- literal_from_ast(key_ast),
           {:ok, value} <- literal_from_ast(value_ast) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp literal_from_ast({:{}, _, values}) do
    values
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case literal_from_ast(value_ast) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.to_tuple()}
      error -> error
    end
  end

  defp literal_from_ast({:__aliases__, _, parts}), do: {:ok, Module.concat(parts)}

  defp literal_from_ast(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case literal_from_ast(value_ast) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.to_tuple()}
      error -> error
    end
  end

  defp literal_from_ast({:-, _, [value_ast]}) do
    with {:ok, value} <- literal_from_ast(value_ast),
         true <- is_number(value) do
      {:ok, -value}
    else
      false -> {:error, {:non_literal_manifest, :-}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp literal_from_ast(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case literal_from_ast(value_ast) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp literal_from_ast(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_atom(value) or is_nil(value),
       do: {:ok, value}

  defp literal_from_ast(other), do: {:error, {:non_literal_manifest, other}}

  defp fetch_optional(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp fetch_string_key(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, {:invalid_manifest, {key, other}}}
    end
  end

  defp fetch_list_key(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_list(value) -> {:ok, value}
      other -> {:error, {:invalid_manifest, {key, other}}}
    end
  end

  defp fetch_supported_format(map) do
    case fetch_optional(map, :format, nil) do
      @revision_file_format -> {:ok, @revision_file_format}
      other -> {:error, {:unsupported_revision_format, other}}
    end
  end

  defp fetch_optional_string_key(map, key) do
    case fetch_optional(map, key, nil) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, {:invalid_manifest, {key, other}}}
    end
  end

  defp fetch_atom_key(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_atom(value) -> {:ok, value}
      other -> {:error, {:invalid_manifest, {key, other}}}
    end
  end

  defp fetch_module_key(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_atom(value) ->
        if module_alias?(value) do
          {:ok, value}
        else
          {:error, {:invalid_manifest, {key, value}}}
        end

      other ->
        {:error, {:invalid_manifest, {key, other}}}
    end
  end

  defp fetch_source_entries(manifest) do
    with {:ok, entries} <- fetch_list_key(manifest, :sources) do
      entries
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
        case validate_source_entry(entry, index) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end

  defp validate_source_entry(entry, index) when is_map(entry) do
    with {:ok, kind} <- fetch_atom_key(entry, :kind),
         {:ok, id} <- fetch_string_key(entry, :id),
         {:ok, module} <- fetch_module_key(entry, :module),
         {:ok, digest} <- fetch_string_key(entry, :digest),
         {:ok, title} <- fetch_optional_string_key(entry, :title) do
      {:ok,
       %{
         kind: kind,
         id: id,
         module: module,
         digest: digest,
         title: title
       }}
    else
      {:error, {:invalid_manifest, reason}} ->
        {:error, {:invalid_manifest, {:source, index, reason}}}

      {:error, reason} ->
        {:error, {:invalid_manifest, {:source, index, reason}}}
    end
  end

  defp validate_source_entry(_other, index),
    do: {:error, {:invalid_manifest, {:source, index, :non_map}}}

  defp fetch_optional_map_key(map, key) do
    case fetch_optional(map, key, nil) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      other -> {:error, {:invalid_manifest, {key, other}}}
    end
  end

  defp artifact_sort_key(%Artifact{} = artifact), do: {artifact.kind, artifact.id}

  defp extract_surface_title(source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, ast} ->
        ast
        |> top_level_forms()
        |> Enum.find_value(fn
          {:defmodule, _, [_module_ast, [do: body]]} -> extract_surface_title_from_body(body)
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp extract_surface_title_from_body(body) do
    body
    |> top_level_forms()
    |> Enum.find_value(fn
      {:surface, _, [opts, _body]} when is_list(opts) -> Keyword.get(opts, :title)
      _ -> nil
    end)
  end

  defp manifest_module_for_app_id(app_id, revision) do
    Module.concat([Ogol, RevisionFile, Macro.camelize(app_id), Macro.camelize(revision)])
  end

  defp exportable_hardware_config?(%{protocol: :ethercat}), do: true
  defp exportable_hardware_config?(_other), do: false

  defp canonical_artifact_id(:hardware_config, _id), do: WorkspaceStore.hardware_config_entry_id()
  defp canonical_artifact_id(_kind, id), do: id

  defp normalize_module_source(source) do
    source
    |> String.trim_trailing("\n")
  end
end
