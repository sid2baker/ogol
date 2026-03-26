defmodule Ogol.Runtime.Actions do
  @moduledoc false

  alias Ogol.Compiler.Model.Action
  alias Ogol.Runtime.Data
  alias Ogol.Runtime.Staging

  @spec run(module(), [Action.t()], Ogol.Runtime.DeliveredEvent.t() | nil, Data.t() | Staging.t()) ::
          {:ok, Staging.t()} | {:error, term()}
  def run(module, actions, delivered, %Data{} = data) do
    run(module, actions, delivered, %Staging{
      data: data,
      request_from: delivered && delivered.from
    })
  end

  def run(module, actions, delivered, %Staging{} = staging) do
    request_from = staging.request_from || (delivered && delivered.from)

    Enum.reduce_while(
      actions,
      {:ok, %{staging | request_from: request_from}},
      fn action, {:ok, staging} ->
        case apply_action(module, action, delivered, staging) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  defp apply_action(
         _module,
         %Action{kind: :set_fact, args: %{name: name, value: value}},
         _delivered,
         staging
       ) do
    next_data = %{staging.data | facts: Map.put(staging.data.facts, name, value)}
    {:ok, %{staging | data: next_data}}
  end

  defp apply_action(
         _module,
         %Action{kind: :set_field, args: %{name: name, value: value}},
         _delivered,
         staging
       ) do
    next_data = %{staging.data | fields: Map.put(staging.data.fields, name, value)}
    {:ok, %{staging | data: next_data}}
  end

  defp apply_action(
         _module,
         %Action{kind: :set_output, args: %{name: name, value: value}},
         _delivered,
         staging
       ) do
    next_data = %{staging.data | outputs: Map.put(staging.data.outputs, name, value)}

    {:ok,
     %{
       staging
       | data: next_data,
         boundary_effects: staging.boundary_effects ++ [{:output, %{name: name, value: value}}]
     }}
  end

  defp apply_action(_module, %Action{kind: :signal, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:signal, args}]}}
  end

  defp apply_action(_module, %Action{kind: :command, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:command, args}]}}
  end

  defp apply_action(_module, %Action{kind: :reply, args: %{value: value}}, _delivered, %Staging{
         request_from: nil
       }) do
    {:error, {:reply_outside_request, value}}
  end

  defp apply_action(_module, %Action{kind: :reply, args: %{value: value}}, _delivered, staging) do
    action = {:reply, staging.request_from, value}

    {:ok,
     %{
       staging
       | reply_count: staging.reply_count + 1,
         otp_actions: staging.otp_actions ++ [action]
     }}
  end

  defp apply_action(
         _module,
         %Action{kind: :internal, args: %{name: name, data: data, meta: meta}},
         _delivered,
         staging
       ) do
    action = {:next_event, :internal, {:ogol_internal, name, data, meta}}
    {:ok, %{staging | otp_actions: staging.otp_actions ++ [action]}}
  end

  defp apply_action(_module, %Action{kind: :state_timeout, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:state_timeout, args}]}}
  end

  defp apply_action(_module, %Action{kind: :cancel_timeout, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:cancel_timeout, args}]}}
  end

  defp apply_action(_module, %Action{kind: :monitor, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:monitor, args}]}}
  end

  defp apply_action(_module, %Action{kind: :demonitor, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:demonitor, args}]}}
  end

  defp apply_action(_module, %Action{kind: :link, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:link, args}]}}
  end

  defp apply_action(_module, %Action{kind: :unlink, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:unlink, args}]}}
  end

  defp apply_action(module, %Action{kind: :callback, args: %{name: name}}, delivered, staging) do
    case invoke_callback_action(module, name, delivered, staging) do
      {:ok, %Staging{} = next_staging} -> {:ok, next_staging}
      {:ok, %Ogol.Runtime.Data{} = next_data} -> {:ok, %{staging | data: next_data}}
      :ok -> {:ok, staging}
      {:error, reason} -> {:error, {:callback_failed, name, reason}}
      other -> {:error, {:invalid_callback_result, name, other}}
    end
  end

  defp apply_action(
         module,
         %Action{kind: :foreign, args: %{kind: kind, module: foreign_module, opts: opts}},
         delivered,
         staging
       ) do
    cond do
      not Code.ensure_loaded?(foreign_module) ->
        {:error, {:foreign_module_unavailable, foreign_module}}

      not function_exported?(foreign_module, :run, 5) ->
        {:error, {:foreign_module_missing_callback, foreign_module}}

      true ->
        case foreign_module.run(kind, opts, module, delivered, staging) do
          {:ok, %Staging{} = next_staging} -> {:ok, next_staging}
          {:error, reason} -> {:error, {:foreign_failed, kind, reason}}
          other -> {:error, {:invalid_foreign_result, kind, other}}
        end
    end
  end

  defp apply_action(_module, %Action{kind: :stop, args: %{reason: reason}}, _delivered, staging) do
    {:ok, %{staging | stop_reason: reason}}
  end

  defp apply_action(_module, %Action{kind: :hibernate}, _delivered, staging) do
    {:ok, %{staging | otp_actions: staging.otp_actions ++ [:hibernate]}}
  end

  defp apply_action(_module, %Action{kind: :send_event, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:send_event, args}]}}
  end

  defp apply_action(
         _module,
         %Action{
           kind: :send_request,
           args: %{target: target, name: name, data: data, meta: meta, timeout: timeout}
         },
         _delivered,
         staging
       ) do
    case Map.get(staging.data.meta, :topology_router) do
      nil ->
        {:error, {:send_request_failed, target, :target_unavailable}}

      router ->
        case Ogol.Topology.Router.send_request(router, target, name, data, meta, timeout) do
          :ok -> {:ok, staging}
          {:error, reason} -> {:error, {:send_request_failed, target, reason}}
        end
    end
  end

  defp invoke_callback_action(module, name, delivered, staging) do
    cond do
      function_exported?(module, name, 3) ->
        apply(module, name, [delivered, staging.data, staging])

      function_exported?(module, name, 2) ->
        apply(module, name, [delivered, staging.data])

      function_exported?(module, name, 1) ->
        apply(module, name, [staging.data])

      true ->
        raise UndefinedFunctionError, module: module, function: name, arity: 3
    end
  end
end
