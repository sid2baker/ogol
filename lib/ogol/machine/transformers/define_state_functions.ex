defmodule Ogol.Machine.Transformers.DefineStateFunctions do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Ogol.Compiler.Normalize
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    machine = Normalize.from_dsl!(dsl_state, module)

    state_defs =
      Enum.map(machine.states, fn {state_name, _state} ->
        transitions = Map.get(machine.transitions_by_source, state_name, [])

        quote generated: true do
          def unquote(state_name)(event_type, event_content, data) do
            case Ogol.Runtime.Normalize.delivered(event_type, event_content, data) do
              nil ->
                {:keep_state, data}

              {:stop, reason} ->
                {:stop, reason, data}

              delivered ->
                __ogol_handle_state_event__(
                  unquote(state_name),
                  delivered,
                  data,
                  unquote(Macro.escape(transitions))
                )
            end
          end
        end
      end)

    {:ok,
     Transformer.eval(
       dsl_state,
       [],
       quote generated: true do
         (unquote_splicing(state_defs))
       end
     )}
  end
end
