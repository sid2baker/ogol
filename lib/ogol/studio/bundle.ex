defmodule Ogol.Studio.Bundle do
  @moduledoc false

  alias Ogol.Studio.Build
  alias Ogol.Studio.DriverDefinition
  alias Ogol.Studio.DriverDraftStore
  alias Ogol.Studio.DriverParser
  alias Ogol.Studio.MachineDefinition
  alias Ogol.Studio.MachineDraftStore

  alias Ogol.HMI.{
    HardwareConfigSource,
    HardwareConfigStore,
    SurfaceDeploymentStore,
    SurfaceDraftStore
  }

  @bundle_kind :studio_bundle
  @bundle_format 1

  defmodule Artifact do
    @moduledoc false

    @type t :: %__MODULE__{
            kind: atom(),
            id: String.t(),
            module: module(),
            source: String.t(),
            source_digest: String.t(),
            sync_state: :synced | :partial | :unsupported,
            model: map() | nil,
            diagnostics: [term()],
            digest_match?: boolean(),
            title: String.t() | nil,
            metadata: map() | nil
          }

    defstruct [
      :kind,
      :id,
      :module,
      :source,
      :source_digest,
      :sync_state,
      :model,
      :title,
      :metadata,
      diagnostics: [],
      digest_match?: true
    ]
  end

  @type t :: %__MODULE__{
          app_id: String.t(),
          title: String.t() | nil,
          format: pos_integer(),
          manifest_module: module(),
          artifacts: [Artifact.t()],
          versioning: map() | nil,
          wiring: map(),
          workspace: map() | nil,
          metadata: map() | nil,
          source: String.t() | nil
        }

  defstruct [
    :app_id,
    :title,
    :manifest_module,
    :versioning,
    :workspace,
    :metadata,
    :source,
    format: @bundle_format,
    wiring: %{},
    artifacts: []
  ]

  @spec export_current(keyword()) :: {:ok, String.t()} | {:error, term()}
  def export_current(opts \\ []) do
    with {:ok, artifacts} <- current_artifacts(),
         {:ok, wiring} <- current_wiring(opts[:wiring] || %{}) do
      bundle = %__MODULE__{
        app_id: opts[:app_id] || "ogol_bundle",
        title: opts[:title],
        format: @bundle_format,
        manifest_module:
          opts[:manifest_module] || manifest_module_for_app_id(opts[:app_id] || "ogol_bundle"),
        versioning: opts[:versioning],
        wiring: wiring,
        workspace: opts[:workspace],
        metadata: opts[:metadata],
        artifacts: Enum.sort_by(artifacts, &artifact_sort_key/1)
      }

      {:ok, render(bundle)}
    end
  end

  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = bundle) do
    manifest_source(bundle) <>
      case bundle.artifacts do
        [] ->
          ""

        artifacts ->
          "\n\n" <>
            Enum.map_join(artifacts, "\n\n", fn artifact ->
              artifact.source
            end)
      end
  end

  @spec import(String.t()) :: {:ok, t()} | {:error, term()}
  def import(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, module_sources} <- extract_module_sources(source, ast),
         {:ok, manifest_module, manifest} <- extract_manifest(module_sources),
         {:ok, artifacts} <- import_artifacts(module_sources, manifest_module, manifest) do
      {:ok,
       %__MODULE__{
         app_id: manifest.app_id,
         title: manifest[:title],
         format: manifest.format,
         manifest_module: manifest_module,
         artifacts: artifacts,
         versioning: manifest[:versioning],
         wiring: manifest.wiring,
         workspace: manifest[:workspace],
         metadata: manifest[:metadata],
         source: source
       }}
    end
  end

  @spec import_into_stores(String.t()) :: {:ok, t()} | {:error, term()}
  def import_into_stores(source) when is_binary(source) do
    with {:ok, %__MODULE__{} = bundle} <- __MODULE__.import(source) do
      Enum.each(bundle.artifacts, &restore_artifact/1)
      {:ok, bundle}
    end
  end

  defp current_artifacts do
    with {:ok, driver_artifacts} <- driver_artifacts_from_store(),
         {:ok, machine_artifacts} <- machine_artifacts_from_store(),
         {:ok, surface_artifacts} <- surface_artifacts_from_store(),
         {:ok, hardware_artifacts} <- hardware_config_artifacts_from_store() do
      {:ok, driver_artifacts ++ machine_artifacts ++ surface_artifacts ++ hardware_artifacts}
    end
  end

  defp current_wiring(extra_wiring) do
    {:ok, Map.merge(collected_wiring(), extra_wiring)}
  end

  defp driver_artifacts_from_store do
    DriverDraftStore.ensure_started()

    DriverDraftStore.list_drafts()
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

  defp surface_artifacts_from_store do
    SurfaceDraftStore.list_drafts()
    |> Enum.map(&surface_artifact_from_draft/1)
    |> then(&{:ok, &1})
  end

  defp machine_artifacts_from_store do
    MachineDraftStore.ensure_started()

    MachineDraftStore.list_drafts()
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

  defp hardware_config_artifacts_from_store do
    HardwareConfigStore.list_configs()
    |> Enum.map(&hardware_config_artifact/1)
    |> then(&{:ok, &1})
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
         source_digest: Build.digest(source),
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
          %{module_name: module_name} -> {:ok, DriverDefinition.module_from_name!(module_name)}
          _ -> {:error, {:artifact_module_not_found, :driver, draft.id}}
        end
    end
  end

  defp surface_artifact_from_draft(draft) do
    source = normalize_module_source(draft.source)

    %Artifact{
      kind: :hmi_surface,
      id: to_string(draft.surface_id),
      module: draft.source_module,
      source: source,
      source_digest: Build.digest(source),
      sync_state: :unsupported,
      diagnostics: [],
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
         source_digest: Build.digest(source),
         sync_state: draft.sync_state,
         model: draft.model,
         diagnostics: draft.sync_diagnostics,
         title: draft.model && draft.model.meaning
       }}
    end
  end

  defp machine_module_from_draft(draft, source) do
    case MachineDefinition.from_source(source) do
      {:ok, model} ->
        {:ok, MachineDefinition.module_from_name!(model.module_name)}

      {:error, _diagnostics} ->
        case draft.model do
          %{module_name: module_name} -> {:ok, MachineDefinition.module_from_name!(module_name)}
          _ -> {:error, {:artifact_module_not_found, :machine, draft.id}}
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
      id: config.id,
      module: HardwareConfigSource.canonical_module(config),
      source: source,
      source_digest: Build.digest(source),
      sync_state: :synced,
      model: config,
      diagnostics: [],
      title: config.label
    }
  end

  defp manifest_source(%__MODULE__{} = bundle) do
    manifest_ast =
      quote do
        defmodule unquote(bundle.manifest_module) do
          @bundle unquote(manifest_map_ast(bundle))
          def manifest, do: @bundle
        end
      end

    manifest_ast
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  defp manifest_map_ast(%__MODULE__{} = bundle) do
    map_ast_from_pairs(
      [
        {:kind, @bundle_kind},
        {:format, bundle.format},
        {:app_id, bundle.app_id},
        optional_pair(:title, bundle.title),
        optional_pair(:versioning, bundle.versioning),
        {:artifacts, {:__raw_ast__, Enum.map(bundle.artifacts, &artifact_entry_ast/1)}},
        {:wiring, bundle.wiring || %{}},
        optional_pair(:workspace, bundle.workspace),
        optional_pair(:metadata, bundle.metadata)
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
        {:source_digest, artifact.source_digest},
        optional_pair(:title, artifact.title),
        optional_pair(:metadata, artifact.metadata)
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
    bundle_attr_ast = Enum.find_value(forms, &bundle_attribute_ast/1)

    case Enum.find_value(forms, &manifest_body_ast/1) do
      nil ->
        {:error, :missing_manifest_function}

      body_ast ->
        body_ast
        |> resolve_manifest_body(bundle_attr_ast)
        |> literal_from_ast()
    end
  end

  defp manifest_from_module_ast(_other), do: {:error, :unsupported_manifest}

  defp bundle_attribute_ast({:@, _, [{:bundle, _, [value_ast]}]}), do: value_ast
  defp bundle_attribute_ast(_other), do: nil

  defp manifest_body_ast({:def, _, [{:manifest, _, args}, [do: {:__block__, _, [body_ast]}]]})
       when args in [nil, []],
       do: body_ast

  defp manifest_body_ast({:def, _, [{:manifest, _, args}, [do: body_ast]]})
       when args in [nil, []],
       do: body_ast

  defp manifest_body_ast(_other), do: nil

  defp resolve_manifest_body({:@, _, [{:bundle, _, _}]}, bundle_attr_ast)
       when not is_nil(bundle_attr_ast),
       do: bundle_attr_ast

  defp resolve_manifest_body(body_ast, _bundle_attr_ast), do: body_ast

  defp validate_manifest(manifest) when is_map(manifest) do
    with :ok <- validate_bundle_kind(manifest),
         {:ok, app_id} <- fetch_string_key(manifest, :app_id),
         {:ok, artifacts} <- fetch_list_key(manifest, :artifacts),
         {:ok, wiring} <- fetch_map_key(manifest, :wiring) do
      {:ok,
       %{
         kind: @bundle_kind,
         format: fetch_optional(manifest, :format, @bundle_format),
         app_id: app_id,
         title: fetch_optional(manifest, :title, nil),
         versioning: fetch_optional(manifest, :versioning, nil),
         artifacts: artifacts,
         wiring: wiring,
         workspace: fetch_optional(manifest, :workspace, nil),
         metadata: fetch_optional(manifest, :metadata, nil)
       }}
    end
  end

  defp validate_manifest(_other), do: {:error, {:invalid_manifest, :non_map}}

  defp validate_bundle_kind(manifest) do
    case fetch_optional(manifest, :kind, nil) do
      @bundle_kind -> :ok
      other -> {:error, {:invalid_manifest, {:kind, other}}}
    end
  end

  defp import_artifacts(module_sources, manifest_module, manifest) do
    modules_by_name =
      module_sources
      |> Enum.reject(&(&1.module == manifest_module))
      |> Map.new(fn %{module: module} = entry -> {module, entry} end)

    with :ok <- ensure_no_unexpected_modules(modules_by_name, manifest.artifacts),
         {:ok, imported} <- do_import_artifacts(modules_by_name, manifest.artifacts) do
      {:ok, Enum.sort_by(imported, &artifact_sort_key/1)}
    end
  end

  defp ensure_no_unexpected_modules(modules_by_name, manifest_artifacts) do
    expected_modules = MapSet.new(Enum.map(manifest_artifacts, &fetch_optional(&1, :module, nil)))
    actual_modules = Map.keys(modules_by_name)

    case Enum.find(actual_modules, &(not MapSet.member?(expected_modules, &1))) do
      nil -> :ok
      module -> {:error, {:unexpected_module, module}}
    end
  end

  defp do_import_artifacts(modules_by_name, manifest_artifacts) do
    Enum.reduce_while(manifest_artifacts, {:ok, []}, fn entry, {:ok, imported} ->
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
    expected_digest = fetch_optional(entry, :source_digest, nil)

    base = %Artifact{
      kind: kind,
      id: fetch_optional(entry, :id, "unknown") |> to_string(),
      module: fetch_optional(entry, :module, nil),
      source: source,
      source_digest: actual_digest,
      title: fetch_optional(entry, :title, nil),
      metadata: fetch_optional(entry, :metadata, nil),
      digest_match?: expected_digest in [nil, actual_digest]
    }

    case classify_artifact(kind, source) do
      {:ok, model} ->
        %{base | sync_state: :synced, model: model}

      {:partial, model, diagnostics} ->
        %{base | sync_state: :partial, model: model, diagnostics: diagnostics}

      {:unsupported, diagnostics} ->
        %{base | sync_state: :unsupported, diagnostics: diagnostics}
    end
  end

  defp classify_artifact(:driver, source) do
    case DriverDefinition.from_source(source) do
      {:ok, model} ->
        {:ok, model}

      {:partial, model, diagnostics} ->
        {:partial, model, diagnostics}

      :unsupported ->
        {:unsupported, ["driver source could not be recovered into the managed Studio subset"]}
    end
  end

  defp classify_artifact(:machine, source) do
    case MachineDefinition.from_source(source) do
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
    if hmi_surface_candidate?(source) do
      {:unsupported,
       [
         "HMI surface source is preserved exactly. Open the artifact in HMI Studio to classify visual availability."
       ]}
    else
      {:unsupported, ["HMI surface source could not be classified from bundle import."]}
    end
  end

  defp classify_artifact(kind, _source) do
    {:unsupported,
     ["No Studio bundle import handler is implemented for kind #{inspect(kind)} yet."]}
  end

  defp restore_artifact(%Artifact{kind: :driver} = artifact) do
    DriverDraftStore.save_source(
      artifact.id,
      artifact.source,
      artifact.model,
      artifact.sync_state,
      artifact.diagnostics
    )
  end

  defp restore_artifact(%Artifact{kind: :machine} = artifact) do
    MachineDraftStore.save_source(
      artifact.id,
      artifact.source,
      artifact.model,
      artifact.sync_state,
      List.wrap(artifact.diagnostics)
    )
  end

  defp restore_artifact(%Artifact{kind: :hmi_surface} = artifact) do
    SurfaceDraftStore.import_source(artifact.id, artifact.source, artifact.module)
  end

  defp restore_artifact(%Artifact{kind: :hardware_config, model: model})
       when is_struct(model, Ogol.HMI.HardwareConfig) do
    HardwareConfigStore.put_config(model)
  end

  defp restore_artifact(_artifact), do: :ok

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

  defp fetch_map_key(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_map(value) -> {:ok, value}
      other -> {:error, {:invalid_manifest, {key, other}}}
    end
  end

  defp artifact_sort_key(%Artifact{} = artifact), do: {artifact.kind, artifact.id}

  defp collected_wiring do
    %{
      deployments: %{},
      panel_assignments: panel_assignments_wiring()
    }
  end

  defp panel_assignments_wiring do
    SurfaceDeploymentStore.list()
    |> Enum.map(fn assignment ->
      {assignment.panel_id,
       %{
         surface_id: assignment.surface_id,
         surface_version: assignment.surface_version,
         default_screen: assignment.default_screen,
         viewport_profile: assignment.viewport_profile
       }}
    end)
    |> Enum.into(%{})
  end

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

  defp hmi_surface_candidate?(source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, ast} ->
        ast
        |> top_level_forms()
        |> Enum.any?(fn
          {:defmodule, _, [_module_ast, [do: body]]} ->
            body
            |> top_level_forms()
            |> Enum.any?(fn
              {:use, _, [{:__aliases__, _, [:Ogol, :HMI, :Surface]} | _]} -> true
              _ -> false
            end)

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  defp manifest_module_for_app_id(app_id) do
    Module.concat([Ogol, Bundle, Macro.camelize(app_id)])
  end

  defp normalize_module_source(source) do
    source
    |> String.trim_trailing("\n")
  end
end
