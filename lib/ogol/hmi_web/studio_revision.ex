defmodule Ogol.HMIWeb.StudioRevision do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Ogol.Studio.Bundle
  alias Ogol.Studio.RevisionStore

  @readonly_title "Saved revision"
  @readonly_message "This revision snapshot is read-only. Switch the Studio header selector back to Draft to edit."

  @spec apply_param(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def apply_param(socket, params) when is_map(params) do
    case params |> Map.get("revision") |> normalize_revision() |> load_selected_revision() do
      {:draft, nil} ->
        socket
        |> assign(:studio_selected_revision, nil)
        |> assign(:studio_selected_revision_bundle, nil)
        |> assign(:studio_read_only?, false)

      {:ok, revision_id, %Bundle{} = bundle} ->
        socket
        |> assign(:studio_selected_revision, revision_id)
        |> assign(:studio_selected_revision_bundle, bundle)
        |> assign(:studio_read_only?, true)
    end
  end

  @spec read_only?(Phoenix.LiveView.Socket.t() | map()) :: boolean()
  def read_only?(%{assigns: assigns}), do: read_only?(assigns)
  def read_only?(%{studio_read_only?: value}) when is_boolean(value), do: value
  def read_only?(_other), do: false

  @spec selected_bundle(Phoenix.LiveView.Socket.t() | map()) :: Bundle.t() | nil
  def selected_bundle(%{assigns: assigns}), do: selected_bundle(assigns)

  def selected_bundle(%{studio_selected_revision_bundle: %Bundle{} = bundle}), do: bundle
  def selected_bundle(_other), do: nil

  @spec path_with_revision(String.t(), Phoenix.LiveView.Socket.t() | map() | String.t() | nil) ::
          String.t()
  def path_with_revision(path, revision_source) when is_binary(path) do
    case revision_id(revision_source) do
      nil ->
        strip_revision(path)

      revision ->
        uri = URI.parse(path)
        query = uri.query |> decode_query() |> Map.put("revision", revision)
        %{uri | query: URI.encode_query(query)} |> URI.to_string()
    end
  end

  @spec readonly_title() :: String.t()
  def readonly_title, do: @readonly_title

  @spec readonly_message() :: String.t()
  def readonly_message, do: @readonly_message

  defp load_selected_revision(nil), do: {:draft, nil}

  defp load_selected_revision(revision_id) do
    with %RevisionStore.Revision{source: source} <- RevisionStore.fetch_revision(revision_id),
         {:ok, %Bundle{} = bundle} <- Bundle.import(source) do
      {:ok, revision_id, bundle}
    else
      _ -> {:draft, nil}
    end
  end

  defp normalize_revision(nil), do: nil
  defp normalize_revision(""), do: nil
  defp normalize_revision(value) when is_binary(value), do: value
  defp normalize_revision(_other), do: nil

  defp revision_id(%{assigns: assigns}), do: revision_id(assigns)
  defp revision_id(%{studio_selected_revision: revision}), do: normalize_revision(revision)
  defp revision_id(revision), do: normalize_revision(revision)

  defp strip_revision(path) do
    uri = URI.parse(path)
    query = uri.query |> decode_query() |> Map.delete("revision")
    normalized_query = if map_size(query) == 0, do: nil, else: URI.encode_query(query)
    %{uri | query: normalized_query} |> URI.to_string()
  end

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)
end
