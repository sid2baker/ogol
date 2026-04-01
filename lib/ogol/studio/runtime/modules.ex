defmodule Ogol.Studio.Modules do
  @moduledoc false

  alias Ogol.Studio.Build.Artifact
  alias Ogol.Studio.RuntimeStore.RuntimeEntry

  def runtime_id(kind, id) when is_atom(kind), do: {kind, to_string(id)}

  @spec apply(term(), Artifact.t()) ::
          {:ok, %{id: term(), module: module(), status: :applied}}
          | {:blocked, %{reason: :old_code_in_use, module: module(), pids: [pid()]}}
          | {:error, term()}
  def apply(id, %Artifact{} = artifact) do
    Ogol.Studio.RuntimeStore.apply_artifact(id, artifact)
  end

  @spec current(term()) :: {:ok, module()} | {:error, :not_found}
  def current(id) do
    case Ogol.Studio.RuntimeStore.fetch(id) do
      %RuntimeEntry{module: module} when is_atom(module) -> {:ok, module}
      _ -> {:error, :not_found}
    end
  end

  @spec status(term()) ::
          {:ok,
           %{
             module: module() | nil,
             source_digest: String.t() | nil,
             blocked_reason: term() | nil,
             lingering_pids: [pid()]
           }}
          | {:error, :not_found}
  def status(id) do
    case Ogol.Studio.RuntimeStore.fetch(id) do
      %RuntimeEntry{} = entry ->
        {:ok,
         %{
           module: entry.module,
           source_digest: entry.source_digest,
           blocked_reason: entry.blocked_reason,
           lingering_pids: entry.lingering_pids
         }}

      nil ->
        {:error, :not_found}
    end
  end

  @spec reset() :: :ok | {:blocked, %{reason: :old_code_in_use, modules: [map()]}}
  def reset do
    Ogol.Studio.RuntimeStore.reset_runtime_modules()
  end
end
