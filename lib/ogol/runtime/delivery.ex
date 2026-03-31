defmodule Ogol.Runtime.Delivery do
  @moduledoc false

  @type event_payload :: map()
  @type event_meta :: map()

  @spec request(GenServer.server(), atom(), event_payload(), event_meta(), timeout()) :: term()
  def request(server, name, data \\ %{}, meta \\ %{}, timeout \\ 5_000)
      when is_atom(name) and is_map(data) and is_map(meta) do
    :gen_statem.call(server, {:request, name, data, meta}, timeout)
  end

  @spec event(GenServer.server(), atom(), event_payload(), event_meta()) :: :ok
  def event(server, name, data \\ %{}, meta \\ %{})
      when is_atom(name) and is_map(data) and is_map(meta) do
    :gen_statem.cast(server, {:event, name, data, meta})
  end

  @spec hardware_event(GenServer.server(), atom(), event_payload(), event_meta()) :: :ok
  def hardware_event(server, name, data \\ %{}, meta \\ %{})
      when is_atom(name) and is_map(data) and is_map(meta) do
    send(server, {:ogol_hardware_event, name, data, meta})
    :ok
  end

  @doc """
  Invoke a public skill on a target machine runtime.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec invoke(pid() | atom(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def invoke(target, skill, args \\ %{}, opts \\ []) do
    meta = Keyword.get(opts, :meta, %{})
    timeout = Keyword.get(opts, :timeout, 5_000)

    with {:ok, %{pid: pid, module: target_module}} <-
           Ogol.Runtime.Target.resolve_machine_runtime(target) do
      case Enum.find(target_module.skills(), &(&1.name == skill)) do
        %Ogol.Skill{kind: :request} ->
          {:ok, request(pid, skill, args, meta, timeout)}

        %Ogol.Skill{kind: :event} ->
          :ok = event(pid, skill, args, meta)
          {:ok, :accepted}

        nil ->
          {:error, {:unknown_skill, skill}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:target_runtime_failure, reason}}
  end
end
