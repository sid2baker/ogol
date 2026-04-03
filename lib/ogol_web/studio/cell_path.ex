defmodule OgolWeb.Studio.CellPath do
  @moduledoc false

  @spec section_path(atom()) :: String.t()
  def section_path(:hmi_surface), do: "/studio/hmis"
  def section_path(:simulator_config), do: "/studio/simulator"
  def section_path(:machine), do: "/studio/machines"
  def section_path(:sequence), do: "/studio/sequences"
  def section_path(:topology), do: "/studio/topology"

  @spec page_path(atom(), String.t(), atom() | nil) :: String.t()
  def page_path(kind, id, view \\ nil)

  def page_path(:hmi_surface, id, _view) when is_binary(id) do
    "/studio/hmis/#{id}"
  end

  def page_path(:simulator_config, id, view) when is_binary(id) do
    build_page_path("/studio/simulator/#{id}", view, :config)
  end

  def page_path(:machine, id, view) when is_binary(id) do
    build_page_path("/studio/machines/#{id}", view, :config)
  end

  def page_path(:sequence, id, view) when is_binary(id) do
    build_page_path("/studio/sequences/#{id}", view, :visual)
  end

  def page_path(:topology, _id, view) do
    build_page_path("/studio/topology", view, :visual)
  end

  @spec show_path(atom(), String.t(), atom() | nil) :: String.t()
  def show_path(kind, id, view \\ nil)

  def show_path(:hmi_surface, id, _view) when is_binary(id) do
    "/studio/cells/hmis/#{id}"
  end

  def show_path(:simulator_config, id, view) when is_binary(id) do
    build_cell_path("/studio/cells/simulator/#{id}", view)
  end

  def show_path(:machine, id, view) when is_binary(id) do
    build_cell_path("/studio/cells/machines/#{id}", view)
  end

  def show_path(:sequence, id, view) when is_binary(id) do
    build_cell_path("/studio/cells/sequences/#{id}", view)
  end

  def show_path(:topology, _id, view) do
    build_cell_path("/studio/cells/topology", view)
  end

  defp build_page_path(base, nil, _default_view), do: base

  defp build_page_path(base, view, default_view) when is_atom(view) do
    if view == default_view, do: base, else: "#{base}/#{view}"
  end

  defp build_page_path(base, view, default_view) when is_binary(view) do
    if view == Atom.to_string(default_view), do: base, else: "#{base}/#{view}"
  end

  defp build_cell_path(base, nil), do: base
  defp build_cell_path(base, view) when is_atom(view), do: "#{base}/#{view}"
  defp build_cell_path(base, view) when is_binary(view), do: "#{base}/#{view}"
end
