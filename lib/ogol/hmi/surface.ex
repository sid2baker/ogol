defmodule Ogol.HMI.Surface do
  @moduledoc """
  Constrained DSL for authored runtime HMI surfaces.

  V1 stays intentionally narrow:

  - curated device-profile variants
  - grid placement
  - one primary node per zone
  - widgets and constrained groups
  - exact profile matching at runtime
  """

  alias Ogol.HMI.Surface.DeviceProfiles

  @overview_required_zones [
    :status_rail,
    :alarm_strip,
    :primary_action_area,
    :machine_tiles,
    :detail_pane,
    :navigation_dock
  ]

  @overview_allowed_zone_ids @overview_required_zones

  @overview_allowed_widget_types %{
    status_rail: [:summary_strip, :status_tile, :state_badge, :value_grid],
    alarm_strip: [:alarm_strip, :fault_list, :status_tile],
    primary_action_area: [
      :procedure_panel,
      :attention_lane,
      :skill_button_group,
      :navigation_buttons
    ],
    machine_tiles: [:machine_grid, :machine_summary_card, :value_grid],
    detail_pane: [:event_ticker, :value_grid, :fault_list],
    navigation_dock: [:quick_links, :navigation_buttons, :skill_button_group]
  }

  @station_required_zones [
    :status_rail,
    :alarm_strip,
    :primary_action_area,
    :detail_pane,
    :navigation_dock
  ]

  @station_allowed_zone_ids @station_required_zones

  @station_allowed_widget_types %{
    status_rail: [:status_tile, :value_grid, :machine_summary_card],
    alarm_strip: [:alarm_strip, :fault_list, :status_tile],
    primary_action_area: [:skill_button_group, :navigation_buttons, :attention_lane],
    detail_pane: [:event_ticker, :value_grid, :fault_list, :machine_summary_card],
    navigation_dock: [:quick_links, :navigation_buttons, :skill_button_group]
  }

  @registered_widget_types [
    :summary_strip,
    :alarm_strip,
    :procedure_panel,
    :attention_lane,
    :machine_grid,
    :event_ticker,
    :quick_links,
    :status_tile,
    :state_badge,
    :fault_list,
    :skill_button_group,
    :machine_summary_card,
    :value_grid,
    :navigation_buttons
  ]

  @allowed_group_modes [:row, :column, :stack, :compact_grid]
  @max_group_children 4

  @template_specs %{
    overview: %{
      required_zones: @overview_required_zones,
      allowed_zone_ids: @overview_allowed_zone_ids,
      allowed_widget_types: @overview_allowed_widget_types
    },
    station: %{
      required_zones: @station_required_zones,
      allowed_zone_ids: @station_allowed_zone_ids,
      allowed_widget_types: @station_allowed_widget_types
    }
  }

  @type role :: :overview | :station | :alarm_console | :maintenance | :supervisor
  @type template :: :overview | :station | :alarm_console

  defmodule BindingRef do
    @moduledoc false

    @type t :: %__MODULE__{name: atom(), source: term()}

    defstruct [:name, :source]
  end

  defmodule Grid do
    @moduledoc false

    @type t :: %__MODULE__{columns: pos_integer(), rows: pos_integer(), gap: atom() | nil}

    defstruct [:columns, :rows, :gap]
  end

  defmodule Widget do
    @moduledoc false

    @type t :: %__MODULE__{
            type: atom(),
            binding: atom() | nil,
            options: map()
          }

    defstruct [:type, :binding, options: %{}]
  end

  defmodule Group do
    @moduledoc false

    @type t :: %__MODULE__{
            mode: atom(),
            children: [Ogol.HMI.Surface.Widget.t()],
            options: map()
          }

    defstruct [:mode, children: [], options: %{}]
  end

  defmodule Zone do
    @moduledoc false

    @type area :: %{
            col: pos_integer(),
            row: pos_integer(),
            col_span: pos_integer(),
            row_span: pos_integer()
          }

    @type render_node :: Ogol.HMI.Surface.Widget.t() | Ogol.HMI.Surface.Group.t()

    @type t :: %__MODULE__{
            id: atom(),
            area: area(),
            node: render_node()
          }

    defstruct [:id, :area, :node]
  end

  defmodule Variant do
    @moduledoc false

    @type t :: %__MODULE__{
            id: atom(),
            profile_id: atom(),
            grid: Ogol.HMI.Surface.Grid.t(),
            zones: %{required(atom()) => Ogol.HMI.Surface.Zone.t()}
          }

    defstruct [:id, :profile_id, :grid, zones: %{}]
  end

  defmodule Screen do
    @moduledoc false

    @type t :: %__MODULE__{
            id: atom(),
            title: String.t() | nil,
            variants: %{required(atom()) => Ogol.HMI.Surface.Variant.t()}
          }

    defstruct [:id, :title, variants: %{}]
  end

  @type t :: %__MODULE__{
          id: String.t() | atom(),
          role: role(),
          template: template(),
          title: String.t(),
          summary: String.t(),
          default_screen: atom() | nil,
          bindings: [BindingRef.t()],
          screens: [Screen.t()]
        }

  defstruct [
    :id,
    :role,
    :template,
    :title,
    :summary,
    :default_screen,
    bindings: [],
    screens: []
  ]

  defmodule Runtime do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t() | atom(),
            role: Ogol.HMI.Surface.role(),
            template: Ogol.HMI.Surface.template(),
            title: String.t(),
            summary: String.t(),
            default_screen: atom(),
            module: module() | nil,
            bindings: %{required(atom()) => Ogol.HMI.Surface.BindingRef.t()},
            screens: %{required(atom()) => Ogol.HMI.Surface.Screen.t()}
          }

    defstruct [
      :id,
      :role,
      :template,
      :title,
      :summary,
      :default_screen,
      :module,
      bindings: %{},
      screens: %{}
    ]
  end

  defmodule Deployment do
    @moduledoc false

    @type t :: %__MODULE__{
            panel_id: atom(),
            surface_id: String.t() | atom(),
            surface_module: module() | nil,
            surface_version: String.t() | nil,
            default_screen: atom(),
            viewport_profile: atom()
          }

    defstruct [
      :panel_id,
      :surface_id,
      :surface_module,
      :surface_version,
      :default_screen,
      :viewport_profile
    ]
  end

  defmacro __using__(_opts) do
    quote do
      import Ogol.HMI.Surface

      Module.register_attribute(__MODULE__, :ogol_hmi_surface_config, persist: false)
      Module.register_attribute(__MODULE__, :ogol_hmi_surface_bindings, accumulate: true)
      Module.register_attribute(__MODULE__, :ogol_hmi_surface_screens, accumulate: true)

      @before_compile Ogol.HMI.Surface
    end
  end

  defmacro surface(opts, do: block) when is_list(opts) do
    quote do
      @ogol_hmi_surface_config unquote(Macro.escape(opts))
      unquote(block)
    end
  end

  defmacro bindings(do: block) do
    quote do
      unquote(block)
    end
  end

  defmacro ref(name, source) do
    quote bind_quoted: [name: name, source: Macro.escape(source)] do
      Module.put_attribute(__MODULE__, :ogol_hmi_surface_bindings, %{name: name, source: source})
      :ok
    end
  end

  defmacro screen(id, opts \\ [], do: block) do
    quote bind_quoted: [id: id, opts: opts, block: Macro.escape(block)] do
      Module.register_attribute(__MODULE__, :ogol_hmi_surface_current_variants, accumulate: true)
      {result, _binding} = Code.eval_quoted(block, [], __ENV__)

      variants =
        __MODULE__
        |> Module.get_attribute(:ogol_hmi_surface_current_variants)
        |> Enum.reverse()
        |> Enum.map(&Ogol.HMI.Surface.build_variant!/1)

      Module.delete_attribute(__MODULE__, :ogol_hmi_surface_current_variants)

      Module.put_attribute(__MODULE__, :ogol_hmi_surface_screens, %{
        id: id,
        opts: opts,
        variants: variants
      })

      result
    end
  end

  defmacro variant(id, do: block) do
    quote bind_quoted: [id: id, block: Macro.escape(block)] do
      Module.register_attribute(__MODULE__, :ogol_hmi_surface_current_variant_zones,
        accumulate: true
      )

      Module.register_attribute(__MODULE__, :ogol_hmi_surface_current_variant_profile,
        persist: false
      )

      Module.register_attribute(__MODULE__, :ogol_hmi_surface_current_grid_columns,
        persist: false
      )

      Module.register_attribute(__MODULE__, :ogol_hmi_surface_current_grid_rows, persist: false)
      Module.register_attribute(__MODULE__, :ogol_hmi_surface_current_grid_gap, persist: false)

      {result, _binding} = Code.eval_quoted(block, [], __ENV__)

      variant = %{
        id: id,
        profile_id: Module.get_attribute(__MODULE__, :ogol_hmi_surface_current_variant_profile),
        grid: %{
          columns: Module.get_attribute(__MODULE__, :ogol_hmi_surface_current_grid_columns),
          rows: Module.get_attribute(__MODULE__, :ogol_hmi_surface_current_grid_rows),
          gap: Module.get_attribute(__MODULE__, :ogol_hmi_surface_current_grid_gap)
        },
        zones:
          __MODULE__
          |> Module.get_attribute(:ogol_hmi_surface_current_variant_zones)
          |> Enum.reverse()
      }

      Module.delete_attribute(__MODULE__, :ogol_hmi_surface_current_variant_zones)
      Module.delete_attribute(__MODULE__, :ogol_hmi_surface_current_variant_profile)
      Module.delete_attribute(__MODULE__, :ogol_hmi_surface_current_grid_columns)
      Module.delete_attribute(__MODULE__, :ogol_hmi_surface_current_grid_rows)
      Module.delete_attribute(__MODULE__, :ogol_hmi_surface_current_grid_gap)

      Module.put_attribute(__MODULE__, :ogol_hmi_surface_current_variants, variant)

      result
    end
  end

  defmacro profile(profile_id) do
    quote bind_quoted: [profile_id: profile_id] do
      Module.put_attribute(__MODULE__, :ogol_hmi_surface_current_variant_profile, profile_id)
      :ok
    end
  end

  defmacro grid(opts) when is_list(opts) do
    quote bind_quoted: [opts: opts] do
      Module.put_attribute(
        __MODULE__,
        :ogol_hmi_surface_current_grid_columns,
        Keyword.get(opts, :columns)
      )

      Module.put_attribute(
        __MODULE__,
        :ogol_hmi_surface_current_grid_rows,
        Keyword.get(opts, :rows)
      )

      Module.put_attribute(
        __MODULE__,
        :ogol_hmi_surface_current_grid_gap,
        Keyword.get(opts, :gap)
      )

      :ok
    end
  end

  defmacro grid(do: block) do
    quote bind_quoted: [block: Macro.escape(block)] do
      {result, _binding} = Code.eval_quoted(block, [], __ENV__)
      result
    end
  end

  defmacro columns(value) do
    quote bind_quoted: [value: value] do
      Module.put_attribute(__MODULE__, :ogol_hmi_surface_current_grid_columns, value)
      :ok
    end
  end

  defmacro rows(value) do
    quote bind_quoted: [value: value] do
      Module.put_attribute(__MODULE__, :ogol_hmi_surface_current_grid_rows, value)
      :ok
    end
  end

  defmacro gap(value) do
    quote bind_quoted: [value: value] do
      Module.put_attribute(__MODULE__, :ogol_hmi_surface_current_grid_gap, value)
      :ok
    end
  end

  defmacro zone(id, opts) when is_list(opts) do
    quote bind_quoted: [id: id, opts_ast: Macro.escape(opts)] do
      {opts, _binding} = Code.eval_quoted(opts_ast, [], __ENV__)

      Module.put_attribute(__MODULE__, :ogol_hmi_surface_current_variant_zones, %{
        id: id,
        opts: opts
      })

      :ok
    end
  end

  defmacro widget(type, opts \\ []) do
    quote do
      Ogol.HMI.Surface.build_widget_node(unquote(type), unquote(Macro.escape(opts)))
    end
  end

  defmacro group(mode, opts \\ []) do
    quote do
      Ogol.HMI.Surface.build_group_node(unquote(mode), unquote(Macro.escape(opts)))
    end
  end

  defmacro __before_compile__(env) do
    config = Module.get_attribute(env.module, :ogol_hmi_surface_config) || []

    definition =
      build_surface!(
        env.module,
        config,
        Module.get_attribute(env.module, :ogol_hmi_surface_bindings) |> Enum.reverse(),
        Module.get_attribute(env.module, :ogol_hmi_surface_screens) |> Enum.reverse()
      )

    runtime = %{compile_definition!(definition) | module: env.module}

    quote do
      def __ogol_hmi_surface__, do: unquote(Macro.escape(definition))
      def __ogol_hmi_surface_runtime__, do: unquote(Macro.escape(runtime))
    end
  end

  @spec definition(module()) :: t()
  def definition(module) when is_atom(module), do: module.__ogol_hmi_surface__()

  @spec runtime(module()) :: Runtime.t()
  def runtime(module) when is_atom(module), do: module.__ogol_hmi_surface_runtime__()

  @spec runtime_from_definition(t()) :: Runtime.t()
  def runtime_from_definition(%__MODULE__{} = definition) do
    %{compile_definition!(definition) | module: nil}
  end

  @spec registered_widget_types() :: [atom()]
  def registered_widget_types, do: @registered_widget_types

  @spec allowed_widget_types(template(), atom()) :: [atom()]
  def allowed_widget_types(template, zone_id) when is_atom(template) and is_atom(zone_id) do
    case Map.get(@template_specs, template) do
      %{allowed_widget_types: allowed_widget_types} -> Map.get(allowed_widget_types, zone_id, [])
      nil -> @registered_widget_types
    end
  end

  def allowed_widget_types(_template, _zone_id), do: @registered_widget_types

  @spec find_screen(Runtime.t(), atom() | String.t() | nil) :: Screen.t() | nil
  def find_screen(%Runtime{screens: screens, default_screen: default_screen}, nil) do
    Map.get(screens, default_screen)
  end

  def find_screen(%Runtime{screens: screens}, screen_id) do
    Enum.find_value(screens, fn {_id, screen} ->
      if to_string(screen.id) == to_string(screen_id), do: screen
    end)
  end

  @spec select_variant(Screen.t(), atom()) :: Variant.t() | nil
  def select_variant(%Screen{variants: variants}, profile_id) when is_atom(profile_id) do
    Map.get(variants, profile_id)
  end

  @spec validate_deployment!(Deployment.t()) :: Deployment.t()
  def validate_deployment!(%Deployment{} = deployment) do
    runtime =
      case deployment.surface_module do
        module when is_atom(module) -> runtime(module)
        _ -> nil
      end

    validate_deployment!(deployment, runtime)
  end

  @spec validate_deployment!(Deployment.t(), Runtime.t() | nil) :: Deployment.t()
  def validate_deployment!(%Deployment{} = deployment, %Runtime{} = runtime) do
    screen = find_screen(runtime, deployment.default_screen)

    cond do
      runtime.id != deployment.surface_id ->
        raise ArgumentError,
              "deployment #{inspect(deployment.panel_id)} surface id #{inspect(deployment.surface_id)} does not match compiled surface #{inspect(runtime.id)}"

      is_nil(DeviceProfiles.fetch(deployment.viewport_profile)) ->
        raise ArgumentError,
              "deployment #{inspect(deployment.panel_id)} references unknown device profile #{inspect(deployment.viewport_profile)}"

      is_nil(screen) ->
        raise ArgumentError,
              "deployment #{inspect(deployment.panel_id)} references unknown screen #{inspect(deployment.default_screen)}"

      is_nil(select_variant(screen, deployment.viewport_profile)) ->
        raise ArgumentError,
              "deployment #{inspect(deployment.panel_id)} has no exact variant for profile #{inspect(deployment.viewport_profile)} on screen #{inspect(deployment.default_screen)}"

      true ->
        deployment
    end
  end

  def validate_deployment!(%Deployment{} = deployment, nil) do
    raise ArgumentError,
          "deployment #{inspect(deployment.panel_id)} references no compiled runtime for #{inspect(deployment.surface_id)}"
  end

  def build_widget_node(type, opts) when is_atom(type) and is_list(opts) do
    {binding, opts} = Keyword.pop(opts, :binding)
    %Widget{type: type, binding: binding, options: Map.new(opts)}
  end

  def build_group_node(mode, opts) when is_atom(mode) and is_list(opts) do
    {children, opts} = Keyword.pop(opts, :widgets, [])

    %Group{
      mode: mode,
      children: Enum.map(children, &normalize_render_node/1),
      options: Map.new(opts)
    }
  end

  @doc false
  def build_variant!(%{id: id, profile_id: profile_id, grid: grid, zones: zones}) do
    %Variant{
      id: id,
      profile_id: profile_id,
      grid: %Grid{
        columns: grid.columns,
        rows: grid.rows,
        gap: grid.gap
      },
      zones:
        zones
        |> Enum.map(&build_zone!/1)
        |> Map.new(fn zone -> {zone.id, zone} end)
    }
  end

  @doc false
  def build_zone!(%{id: id, opts: opts}) do
    %Zone{
      id: id,
      area: normalize_area!(Keyword.fetch!(opts, :area)),
      node: Keyword.fetch!(opts, :node)
    }
  end

  defp normalize_area!({col, row, col_span, row_span})
       when is_integer(col) and is_integer(row) and is_integer(col_span) and is_integer(row_span) do
    %{col: col, row: row, col_span: col_span, row_span: row_span}
  end

  defp normalize_area!(other) do
    raise ArgumentError, "invalid zone area #{inspect(other)}"
  end

  defp build_surface!(module, config, binding_refs, screens) do
    %__MODULE__{
      id: Keyword.fetch!(config, :id),
      role: Keyword.fetch!(config, :role),
      template: Keyword.fetch!(config, :template),
      title: Keyword.fetch!(config, :title),
      summary: Keyword.fetch!(config, :summary),
      default_screen: Keyword.get(config, :default_screen),
      bindings: Enum.map(binding_refs, &build_binding_ref!/1),
      screens: Enum.map(screens, &build_screen!/1)
    }
    |> validate_surface!(module)
  end

  defp build_binding_ref!(%{name: name, source: source}),
    do: %BindingRef{name: name, source: normalize_binding_source(source)}

  defp build_screen!(%{id: id, opts: opts, variants: variants}) do
    %Screen{
      id: id,
      title: Keyword.get(opts, :title),
      variants: Map.new(variants, &{&1.profile_id, &1})
    }
  end

  defp validate_surface!(%__MODULE__{screens: []}, module) do
    raise ArgumentError, "#{inspect(module)} must define at least one screen"
  end

  defp validate_surface!(%__MODULE__{bindings: bindings, screens: screens} = definition, module) do
    ensure_unique!(bindings, & &1.name, "#{inspect(module)} defines duplicate binding refs")
    ensure_unique!(screens, & &1.id, "#{inspect(module)} defines duplicate screen ids")

    binding_names = MapSet.new(bindings, & &1.name)

    Enum.each(screens, fn screen ->
      validate_screen!(definition, screen, binding_names, module)
    end)

    default_screen = definition.default_screen || hd(screens).id

    if Enum.any?(screens, &(&1.id == default_screen)) do
      %{definition | default_screen: default_screen}
    else
      raise ArgumentError,
            "#{inspect(module)} references unknown default screen #{inspect(default_screen)}"
    end
  end

  defp validate_screen!(definition, %Screen{} = screen, binding_names, module) do
    variants = Map.values(screen.variants)

    if variants == [] do
      raise ArgumentError,
            "#{inspect(module)} screen #{inspect(screen.id)} must define at least one variant"
    end

    ensure_unique!(
      variants,
      & &1.id,
      "#{inspect(module)} screen #{inspect(screen.id)} defines duplicate variant ids"
    )

    ensure_unique!(
      variants,
      & &1.profile_id,
      "#{inspect(module)} screen #{inspect(screen.id)} defines duplicate profile variants"
    )

    Enum.each(variants, fn variant ->
      validate_variant!(definition, screen, variant, binding_names, module)
    end)
  end

  defp validate_variant!(definition, screen, variant, binding_names, module) do
    validate_profile!(variant.profile_id, module, screen.id, variant.id)
    validate_grid!(variant.grid, module, screen.id, variant.id)

    zone_ids = Map.keys(variant.zones)

    case Map.get(@template_specs, definition.template) do
      %{required_zones: required_zones, allowed_zone_ids: allowed_zone_ids} ->
        missing = required_zones -- zone_ids

        if missing != [] do
          raise ArgumentError,
                "#{inspect(module)} screen #{inspect(screen.id)} variant #{inspect(variant.id)} is missing required zones #{inspect(missing)}"
        end

        invalid = zone_ids -- allowed_zone_ids

        if invalid != [] do
          raise ArgumentError,
                "#{inspect(module)} screen #{inspect(screen.id)} variant #{inspect(variant.id)} defines unsupported #{definition.template} zones #{inspect(invalid)}"
        end

      nil ->
        :ok
    end

    validate_zone_fit_and_overlap!(variant, module, screen.id)

    Enum.each(variant.zones, fn {_zone_id, zone} ->
      validate_zone!(definition, zone, binding_names, module, screen.id, variant.id)
    end)
  end

  defp validate_profile!(profile_id, module, screen_id, variant_id) do
    if is_nil(DeviceProfiles.fetch(profile_id)) do
      raise ArgumentError,
            "#{inspect(module)} screen #{inspect(screen_id)} variant #{inspect(variant_id)} references unknown device profile #{inspect(profile_id)}"
    end
  end

  defp validate_grid!(%Grid{columns: columns, rows: rows}, _module, _screen_id, _variant_id)
       when is_integer(columns) and columns > 0 and is_integer(rows) and rows > 0,
       do: :ok

  defp validate_grid!(_grid, module, screen_id, variant_id) do
    raise ArgumentError,
          "#{inspect(module)} screen #{inspect(screen_id)} variant #{inspect(variant_id)} defines an invalid grid"
  end

  defp validate_zone_fit_and_overlap!(%Variant{grid: grid, zones: zones}, module, screen_id) do
    cells =
      Enum.reduce(zones, %{}, fn {_id, zone}, acc ->
        area = zone.area

        if area.col < 1 or area.row < 1 or area.col_span < 1 or area.row_span < 1 or
             area.col + area.col_span - 1 > grid.columns or
             area.row + area.row_span - 1 > grid.rows do
          raise ArgumentError,
                "#{inspect(module)} screen #{inspect(screen_id)} zone #{inspect(zone.id)} exceeds the grid"
        end

        Enum.reduce(area_cells(area), acc, fn cell, cell_acc ->
          case Map.get(cell_acc, cell) do
            nil ->
              Map.put(cell_acc, cell, zone.id)

            other_zone ->
              raise ArgumentError,
                    "#{inspect(module)} screen #{inspect(screen_id)} zones #{inspect(other_zone)} and #{inspect(zone.id)} overlap at #{inspect(cell)}"
          end
        end)
      end)

    _ = cells
    :ok
  end

  defp area_cells(%{col: col, row: row, col_span: col_span, row_span: row_span}) do
    for current_col <- col..(col + col_span - 1),
        current_row <- row..(row + row_span - 1) do
      {current_col, current_row}
    end
  end

  defp validate_zone!(definition, zone, binding_names, module, screen_id, variant_id) do
    if is_nil(zone.node) do
      raise ArgumentError,
            "#{inspect(module)} screen #{inspect(screen_id)} variant #{inspect(variant_id)} zone #{inspect(zone.id)} has no render node"
    end

    allowed_widgets =
      allowed_widget_types(definition.template, zone.id)

    validate_node!(
      zone.node,
      allowed_widgets,
      binding_names,
      module,
      screen_id,
      variant_id,
      zone.id
    )
  end

  defp validate_node!(
         %Widget{} = widget,
         allowed_widgets,
         binding_names,
         module,
         screen_id,
         variant_id,
         zone_id
       ) do
    validate_widget_type!(widget.type, module, screen_id, variant_id, zone_id)

    if widget.type not in allowed_widgets do
      raise ArgumentError,
            "#{inspect(module)} screen #{inspect(screen_id)} variant #{inspect(variant_id)} zone #{inspect(zone_id)} does not allow widget #{inspect(widget.type)}"
    end

    validate_binding_ref!(widget.binding, binding_names, module, screen_id, variant_id, zone_id)
  end

  defp validate_node!(
         %Group{} = group,
         allowed_widgets,
         binding_names,
         module,
         screen_id,
         variant_id,
         zone_id
       ) do
    if group.mode not in @allowed_group_modes do
      raise ArgumentError,
            "#{inspect(module)} screen #{inspect(screen_id)} variant #{inspect(variant_id)} zone #{inspect(zone_id)} uses unsupported group mode #{inspect(group.mode)}"
    end

    child_count = length(group.children)

    if child_count < 1 or child_count > @max_group_children do
      raise ArgumentError,
            "#{inspect(module)} screen #{inspect(screen_id)} variant #{inspect(variant_id)} zone #{inspect(zone_id)} uses invalid group child count #{child_count}"
    end

    Enum.each(group.children, fn child ->
      validate_node!(
        child,
        allowed_widgets,
        binding_names,
        module,
        screen_id,
        variant_id,
        zone_id
      )
    end)
  end

  defp validate_binding_ref!(nil, _binding_names, _module, _screen_id, _variant_id, _zone_id),
    do: :ok

  defp validate_binding_ref!(binding, binding_names, module, screen_id, variant_id, zone_id) do
    unless MapSet.member?(binding_names, binding) do
      raise ArgumentError,
            "#{inspect(module)} screen #{inspect(screen_id)} variant #{inspect(variant_id)} zone #{inspect(zone_id)} references unknown binding #{inspect(binding)}"
    end
  end

  defp validate_widget_type!(type, module, screen_id, variant_id, zone_id) do
    if type not in @registered_widget_types do
      raise ArgumentError,
            "#{inspect(module)} screen #{inspect(screen_id)} variant #{inspect(variant_id)} zone #{inspect(zone_id)} references unknown widget #{inspect(type)}"
    end
  end

  defp compile_definition!(%__MODULE__{} = definition) do
    %Runtime{
      id: definition.id,
      role: definition.role,
      template: definition.template,
      title: definition.title,
      summary: definition.summary,
      default_screen: definition.default_screen,
      module: nil,
      bindings: Map.new(definition.bindings, &{&1.name, &1}),
      screens: Map.new(definition.screens, &{&1.id, &1})
    }
  end

  defp ensure_unique!(items, key_fun, message) do
    items
    |> Enum.group_by(key_fun)
    |> Enum.find(fn {_key, grouped} -> length(grouped) > 1 end)
    |> case do
      nil -> :ok
      {_key, _grouped} -> raise ArgumentError, message
    end
  end

  defp normalize_render_node(%Widget{} = widget), do: widget
  defp normalize_render_node(%Group{} = group), do: group
  defp normalize_render_node({:widget, _meta, [type]}), do: build_widget_node(type, [])
  defp normalize_render_node({:widget, _meta, [type, opts]}), do: build_widget_node(type, opts)
  defp normalize_render_node({:group, _meta, [mode]}), do: build_group_node(mode, [])
  defp normalize_render_node({:group, _meta, [mode, opts]}), do: build_group_node(mode, opts)
  defp normalize_render_node(other), do: other

  defp normalize_binding_source(source) do
    if Macro.quoted_literal?(source) do
      {value, _binding} = Code.eval_quoted(source, [], __ENV__)
      value
    else
      source
    end
  end
end
