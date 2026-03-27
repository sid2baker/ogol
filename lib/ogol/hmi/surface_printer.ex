defmodule Ogol.HMI.SurfacePrinter do
  @moduledoc false

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.{BindingRef, Group, Screen, Variant, Widget, Zone}

  @spec print(Surface.t(), keyword()) :: String.t()
  def print(%Surface{} = definition, opts \\ []) do
    definition
    |> to_quoted(opts)
    |> Code.quoted_to_algebra()
    |> Inspect.Algebra.format(98)
    |> IO.iodata_to_binary()
  end

  @spec to_quoted(Surface.t(), keyword()) :: Macro.t()
  def to_quoted(%Surface{} = definition, opts \\ []) do
    module = Keyword.get(opts, :module, canonical_module(definition))

    {:defmodule, [],
     [
       alias_ast(module),
       [
         do:
           do_block([
             {:use, [], [alias_ast(Ogol.HMI.Surface)]},
             surface_ast(definition)
           ])
       ]
     ]}
  end

  @spec canonical_module(Surface.t()) :: module()
  def canonical_module(%Surface{id: id}) do
    Module.concat([Ogol, HMI, Surfaces, StudioDrafts, Macro.camelize(to_string(id))])
  end

  defp surface_ast(%Surface{} = definition) do
    opts = [
      id: definition.id,
      role: definition.role,
      template: definition.template,
      title: definition.title,
      summary: definition.summary,
      default_screen: definition.default_screen
    ]

    {:surface, [],
     [
       opts,
       [do: do_block([bindings_ast(definition) | Enum.map(definition.screens, &screen_ast/1)])]
     ]}
  end

  defp bindings_ast(%Surface{bindings: bindings}) do
    {:bindings, [], [[do: do_block(Enum.map(bindings, &binding_ast/1))]]}
  end

  defp binding_ast(%BindingRef{name: name, source: source}) do
    {:ref, [], [name, Macro.escape(source)]}
  end

  defp screen_ast(%Screen{id: id, title: title, variants: variants}) do
    opts = if title, do: [title: title], else: []

    {:screen, [],
     [
       id,
       opts,
       [
         do:
           do_block(
             variants
             |> Map.values()
             |> Enum.sort_by(& &1.profile_id)
             |> Enum.map(&variant_ast/1)
           )
       ]
     ]}
  end

  defp variant_ast(%Variant{id: id, profile_id: profile_id, grid: grid, zones: zones}) do
    body =
      [
        {:profile, [], [profile_id]},
        {:grid, [], [[columns: grid.columns, rows: grid.rows, gap: grid.gap]]}
        | zones
          |> Map.values()
          |> Enum.sort_by(& &1.id)
          |> Enum.map(&zone_ast/1)
      ]

    {:variant, [], [id, [do: do_block(body)]]}
  end

  defp zone_ast(%Zone{id: id, area: area, node: node}) do
    opts = [
      area: {area.col, area.row, area.col_span, area.row_span},
      node: node_ast(node)
    ]

    {:zone, [], [id, opts]}
  end

  defp node_ast(%Widget{type: type, binding: binding, options: options}) do
    opts =
      options
      |> Map.to_list()
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> then(fn opts ->
        if binding, do: Keyword.put(opts, :binding, binding), else: opts
      end)

    {:widget, [], [type, opts]}
  end

  defp node_ast(%Group{mode: mode, children: children, options: options}) do
    opts =
      options
      |> Map.to_list()
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Keyword.put(:widgets, Enum.map(children, &node_ast/1))

    {:group, [], [mode, opts]}
  end

  defp alias_ast(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.map(&String.to_atom/1)
    |> then(&{:__aliases__, [], &1})
  end

  defp do_block(forms), do: {:__block__, [], forms}
end
