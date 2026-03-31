defmodule Ogol.Authoring.MachineSource do
  @moduledoc false

  alias Ogol.Authoring.MachineArtifact
  alias Ogol.Authoring.MachineDiagnostic
  alias Ogol.Authoring.MachineLowering
  alias Ogol.Authoring.MachineModel

  @editable_actions MapSet.new([
                      :set_fact,
                      :set_field,
                      :set_output,
                      :signal,
                      :command,
                      :reply,
                      :state_timeout,
                      :cancel_timeout
                    ])

  @partial_actions MapSet.new([
                     :internal,
                     :stop,
                     :hibernate
                   ])

  @managed_sections MapSet.new([
                      :machine,
                      :boundary,
                      :memory,
                      :states,
                      :transitions,
                      :safety,
                      :children
                    ])
  @ancillary_top_level MapSet.new([:use, :require, :alias, :import, :@, :def, :defp])
  @boundary_kinds MapSet.new([:fact, :event, :request, :command, :output, :signal])

  defguardp simple_scalar(value)
            when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
                   is_binary(value) or is_atom(value)

  @spec load_file(Path.t()) :: {:ok, MachineArtifact.t()} | {:error, MachineArtifact.t()}
  def load_file(path) do
    path
    |> File.read!()
    |> load_source(path: path)
  end

  @spec load_source(String.t(), keyword()) ::
          {:ok, MachineArtifact.t()} | {:error, MachineArtifact.t()}
  def load_source(source, opts \\ []) when is_binary(source) do
    artifact = %MachineArtifact{
      path: opts[:path],
      source: source,
      uses_ogol_machine?: false,
      compatibility: :not_visually_editable
    }

    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, ast} ->
        analyzed =
          ast
          |> analyze(artifact)
          |> finalize()

        {:ok, analyzed}

      {:error, {line, error, token}} ->
        diagnostic =
          diagnostic(
            :rejected,
            :parse_error,
            "failed to parse source: #{inspect(error)} #{inspect(token)}",
            :file,
            line,
            1
          )

        {:error, %{artifact | diagnostics: [diagnostic]}}
    end
  end

  @spec load_model_file(Path.t()) :: {:ok, MachineModel.t()} | {:error, MachineArtifact.t()}
  def load_model_file(path) do
    with {:ok, artifact} <- load_file(path),
         {:ok, model} <- MachineLowering.lower_artifact(artifact) do
      {:ok, model}
    else
      {:error, %MachineArtifact{} = artifact} -> {:error, artifact}
      {:ok, %MachineArtifact{} = artifact} -> {:error, artifact}
    end
  end

  @spec load_model_source(String.t(), keyword()) ::
          {:ok, MachineModel.t()} | {:error, MachineArtifact.t()}
  def load_model_source(source, opts \\ []) do
    with {:ok, artifact} <- load_source(source, opts),
         {:ok, model} <- MachineLowering.lower_artifact(artifact) do
      {:ok, model}
    else
      {:error, %MachineArtifact{} = artifact} -> {:error, artifact}
      {:ok, %MachineArtifact{} = artifact} -> {:error, artifact}
    end
  end

  defp analyze(ast, artifact) do
    top_level_forms = to_forms(ast)
    module_forms = Enum.filter(top_level_forms, &match?({:defmodule, _, _}, &1))

    artifact =
      case module_forms do
        [{:defmodule, _meta, [_name_ast, [do: body]]}] ->
          analyze_module(body, %{artifact | ast: ast, module: module_name(module_forms)})

        [] ->
          add_diagnostic(
            artifact,
            :rejected,
            :missing_machine_module,
            "expected exactly one machine module",
            :file,
            nil,
            nil
          )

        _ ->
          add_diagnostic(
            artifact,
            :rejected,
            :multiple_modules,
            "machine authoring currently expects exactly one module per file",
            :file,
            nil,
            nil
          )
      end

    artifact
  end

  defp module_name([{:defmodule, _meta, [name_ast, _]} | _]) do
    case name_ast do
      {:__aliases__, _, parts} -> Module.concat(parts)
      atom when is_atom(atom) -> atom
      _ -> nil
    end
  end

  defp analyze_module(body, artifact) do
    forms = to_forms(body)

    state = %{
      artifact: artifact,
      section_presence: %{},
      state_names: MapSet.new(),
      initial_states: [],
      field_names: MapSet.new(),
      child_names: MapSet.new(),
      boundary_names: %{
        fact: MapSet.new(),
        event: MapSet.new(),
        request: MapSet.new(),
        command: MapSet.new(),
        output: MapSet.new(),
        signal: MapSet.new()
      },
      helper_defs?: false
    }

    state =
      Enum.reduce(forms, state, fn form, acc ->
        analyze_top_level_form(form, acc)
      end)

    artifact =
      state.artifact
      |> Map.put(:uses_ogol_machine?, uses_ogol_machine?(forms))
      |> Map.put(:sections, state.section_presence)

    artifact =
      if artifact.uses_ogol_machine? do
        artifact
      else
        add_diagnostic(
          artifact,
          :rejected,
          :missing_use_ogol_machine,
          "managed machine source must `use Ogol.Machine`",
          :module,
          nil,
          nil
        )
      end

    cond do
      not state.helper_defs? ->
        artifact

      rejected_free?(artifact) and partial_present?(artifact) ->
        add_diagnostic(
          artifact,
          :partial,
          :helper_functions_present,
          "helper functions are inspect-only because the file is already partially representable",
          :module,
          nil,
          nil
        )

      rejected_free?(artifact) ->
        add_diagnostic(
          artifact,
          :rejected,
          :helper_functions_present,
          "helper functions are not part of the editable managed subset",
          :module,
          nil,
          nil
        )

      true ->
        artifact
    end
  end

  defp uses_ogol_machine?(forms) do
    Enum.any?(forms, fn
      {:use, _, [{:__aliases__, _, [:Ogol, :Machine]} | _]} -> true
      _ -> false
    end)
  end

  defp analyze_top_level_form({name, meta, args} = form, state)
       when is_atom(name) and is_list(args) do
    cond do
      MapSet.member?(@managed_sections, name) ->
        analyze_section(form, state)

      name in [:def, :defp] ->
        %{state | helper_defs?: true}

      MapSet.member?(@ancillary_top_level, name) ->
        state

      true ->
        %{
          state
          | artifact:
              add_diagnostic(
                state.artifact,
                :rejected,
                :unsupported_top_level_form,
                "unsupported top-level form #{inspect(name)}",
                :module,
                meta[:line],
                meta[:column]
              )
        }
    end
  end

  defp analyze_top_level_form(_other, state), do: state

  defp analyze_section({section, meta, args}, state) do
    case split_do_args(args) do
      {:ok, _prefix, body} ->
        section_state = put_in(state.section_presence[section], true)

        body
        |> to_forms()
        |> Enum.reduce(section_state, fn entry, acc ->
          analyze_section_entry(section, entry, acc)
        end)

      :error ->
        %{
          state
          | artifact:
              add_diagnostic(
                state.artifact,
                :rejected,
                :invalid_section_form,
                "section #{inspect(section)} must use `do ... end` form",
                section,
                meta[:line],
                meta[:column]
              )
        }
    end
  end

  defp analyze_section_entry(:machine, {name, meta, args}, state)
       when is_atom(name) and is_list(args) do
    case name do
      field when field in [:name, :meaning, :hardware_adapter] ->
        state

      :hardware_ref ->
        if editable_hardware_ref?(args) do
          state
        else
          %{
            state
            | artifact:
                add_diagnostic(
                  state.artifact,
                  :rejected,
                  :non_literal_hardware_ref,
                  "`hardware_ref(...)` must stay within the editable literal subset",
                  :machine,
                  meta[:line],
                  meta[:column]
                )
          }
        end

      other ->
        case args do
          [value] when simple_scalar(value) ->
            %{
              state
              | artifact:
                  add_diagnostic(
                    state.artifact,
                    :partial,
                    :additional_machine_metadata,
                    "additional machine metadata #{inspect(other)} is inspect-only in v1",
                    :machine,
                    meta[:line],
                    meta[:column]
                  )
            }

          _ ->
            %{
              state
              | artifact:
                  add_diagnostic(
                    state.artifact,
                    :rejected,
                    :unsupported_machine_entry,
                    "unsupported machine entry #{inspect(other)}",
                    :machine,
                    meta[:line],
                    meta[:column]
                  )
            }
        end
    end
  end

  defp analyze_section_entry(:boundary, {name, meta, args}, state)
       when is_atom(name) and is_list(args) do
    if MapSet.member?(@boundary_kinds, name) do
      boundary_name =
        case args do
          [boundary_name | _] when is_atom(boundary_name) -> boundary_name
          _ -> nil
        end

      artifact =
        if is_nil(boundary_name) do
          add_diagnostic(
            state.artifact,
            :rejected,
            :invalid_boundary_entry,
            "boundary declaration #{inspect(name)} is missing a valid atom name",
            :boundary,
            meta[:line],
            meta[:column]
          )
        else
          state.artifact
        end

      boundary_names =
        if is_nil(boundary_name) do
          state.boundary_names
        else
          seen = Map.fetch!(state.boundary_names, name)

          if MapSet.member?(seen, boundary_name) do
            add_diagnostic(
              artifact,
              :rejected,
              :duplicate_boundary_name,
              "duplicate #{inspect(name)} declaration #{inspect(boundary_name)}",
              :boundary,
              meta[:line],
              meta[:column]
            )

            state.boundary_names
          else
            Map.put(state.boundary_names, name, MapSet.put(seen, boundary_name))
          end
        end

      %{state | artifact: artifact, boundary_names: boundary_names}
    else
      %{
        state
        | artifact:
            add_diagnostic(
              state.artifact,
              :rejected,
              :unknown_boundary_declaration,
              "unknown boundary declaration #{inspect(name)}",
              :boundary,
              meta[:line],
              meta[:column]
            )
      }
    end
  end

  defp analyze_section_entry(:memory, {:field, meta, [field_name | _]}, state)
       when is_atom(field_name) do
    if MapSet.member?(state.field_names, field_name) do
      %{
        state
        | artifact:
            add_diagnostic(
              state.artifact,
              :rejected,
              :duplicate_field_name,
              "duplicate field declaration #{inspect(field_name)}",
              :memory,
              meta[:line],
              meta[:column]
            )
      }
    else
      %{state | field_names: MapSet.put(state.field_names, field_name)}
    end
  end

  defp analyze_section_entry(:memory, {name, meta, _args}, state) when is_atom(name) do
    %{
      state
      | artifact:
          add_diagnostic(
            state.artifact,
            :rejected,
            :unknown_memory_declaration,
            "unknown memory declaration #{inspect(name)}",
            :memory,
            meta[:line],
            meta[:column]
          )
    }
  end

  defp analyze_section_entry(:states, {:state, meta, [state_name | rest]}, state)
       when is_atom(state_name) do
    if MapSet.member?(state.state_names, state_name) do
      %{
        state
        | artifact:
            add_diagnostic(
              state.artifact,
              :rejected,
              :duplicate_state_name,
              "duplicate state declaration #{inspect(state_name)}",
              :states,
              meta[:line],
              meta[:column]
            )
      }
    else
      {state, body} =
        case split_do_args(rest) do
          {:ok, _prefix, body} ->
            {%{state | state_names: MapSet.put(state.state_names, state_name)}, body}

          :error ->
            artifact =
              add_diagnostic(
                state.artifact,
                :rejected,
                :invalid_state_form,
                "state #{inspect(state_name)} must use `do ... end` form",
                :states,
                meta[:line],
                meta[:column]
              )

            {%{
               state
               | artifact: artifact,
                 state_names: MapSet.put(state.state_names, state_name)
             }, []}
        end

      Enum.reduce(to_forms(body), state, fn entry, acc ->
        analyze_state_entry(entry, state_name, acc)
      end)
    end
  end

  defp analyze_section_entry(:states, {name, meta, _args}, state) when is_atom(name) do
    %{
      state
      | artifact:
          add_diagnostic(
            state.artifact,
            :rejected,
            :unknown_states_entry,
            "unknown states declaration #{inspect(name)}",
            :states,
            meta[:line],
            meta[:column]
          )
    }
  end

  defp analyze_section_entry(
         :transitions,
         {:transition, meta, [source, destination | rest]},
         state
       )
       when is_atom(source) and is_atom(destination) do
    body =
      case split_do_args(rest) do
        {:ok, _prefix, body} -> body
        :error -> []
      end

    Enum.reduce(to_forms(body), state, fn entry, acc ->
      analyze_transition_entry(entry, %{source: source, destination: destination}, acc)
    end)
    |> maybe_flag_invalid_transition_form(meta, rest)
  end

  defp analyze_section_entry(:transitions, {name, meta, _args}, state) when is_atom(name) do
    %{
      state
      | artifact:
          add_diagnostic(
            state.artifact,
            :rejected,
            :unknown_transitions_entry,
            "unknown transitions declaration #{inspect(name)}",
            :transitions,
            meta[:line],
            meta[:column]
          )
    }
  end

  defp analyze_section_entry(:safety, {name, meta, _args}, state)
       when name in [:always, :while_in] do
    %{
      state
      | artifact:
          add_diagnostic(
            state.artifact,
            :partial,
            :safety_rule_present,
            "safety rules are inspect-only in the first machine editor",
            :safety,
            meta[:line],
            meta[:column]
          )
    }
  end

  defp analyze_section_entry(:safety, {name, meta, _args}, state) when is_atom(name) do
    %{
      state
      | artifact:
          add_diagnostic(
            state.artifact,
            :rejected,
            :unknown_safety_rule,
            "unknown safety declaration #{inspect(name)}",
            :safety,
            meta[:line],
            meta[:column]
          )
    }
  end

  defp analyze_section_entry(:children, {:child, meta, [child_name | _rest]}, state)
       when is_atom(child_name) do
    artifact =
      add_diagnostic(
        state.artifact,
        :partial,
        :children_present,
        "child declarations are inspect-only in the first machine editor",
        :children,
        meta[:line],
        meta[:column]
      )

    if MapSet.member?(state.child_names, child_name) do
      %{
        state
        | artifact:
            add_diagnostic(
              artifact,
              :rejected,
              :duplicate_child_name,
              "duplicate child declaration #{inspect(child_name)}",
              :children,
              meta[:line],
              meta[:column]
            )
      }
    else
      %{state | artifact: artifact, child_names: MapSet.put(state.child_names, child_name)}
    end
  end

  defp analyze_section_entry(:children, {name, meta, _args}, state) when is_atom(name) do
    %{
      state
      | artifact:
          add_diagnostic(
            state.artifact,
            :rejected,
            :unknown_children_entry,
            "unknown children declaration #{inspect(name)}",
            :children,
            meta[:line],
            meta[:column]
          )
    }
  end

  defp analyze_section_entry(_section, _entry, state), do: state

  defp analyze_state_entry({:initial?, meta, [true]}, state_name, state) do
    %{state | initial_states: [{state_name, meta[:line], meta[:column]} | state.initial_states]}
  end

  defp analyze_state_entry({name, _meta, _args}, _state_name, state)
       when name in [:initial?, :meaning, :status] do
    state
  end

  defp analyze_state_entry({name, meta, _args}, _state_name, state) when is_atom(name) do
    classify_action(name, meta, :states, state)
  end

  defp analyze_state_entry(_entry, _state_name, state), do: state

  defp analyze_transition_entry({:on, meta, [trigger]}, context, state) do
    classify_trigger(trigger, meta, context, state)
  end

  defp analyze_transition_entry({name, _meta, _args}, _context, state)
       when name in [:guard, :priority, :reenter?, :meaning] do
    state
  end

  defp analyze_transition_entry({name, meta, _args}, _context, state) when is_atom(name) do
    classify_action(name, meta, :transitions, state)
  end

  defp analyze_transition_entry(_entry, _context, state), do: state

  defp classify_trigger({family, name}, _meta, _context, state)
       when family in [:event, :request] and is_atom(name),
       do: state

  defp classify_trigger({family, _name}, meta, _context, state)
       when family in [:hardware, :state_timeout] do
    %{
      state
      | artifact:
          add_diagnostic(
            state.artifact,
            :partial,
            :runtime_family_trigger,
            "runtime-family triggers are inspect-only in v1",
            :transitions,
            meta[:line],
            meta[:column]
          )
    }
  end

  defp classify_trigger(name, meta, _context, state) when is_atom(name) do
    %{
      state
      | artifact:
          add_diagnostic(
            state.artifact,
            :partial,
            :bare_trigger_requires_inference,
            "bare triggers are not part of the editable v1 trigger subset",
            :transitions,
            meta[:line],
            meta[:column]
          )
    }
  end

  defp classify_trigger(_other, meta, _context, state) do
    %{
      state
      | artifact:
          add_diagnostic(
            state.artifact,
            :rejected,
            :unsupported_trigger_form,
            "unsupported trigger form",
            :transitions,
            meta[:line],
            meta[:column]
          )
    }
  end

  defp classify_action(name, meta, section, state) do
    cond do
      MapSet.member?(@editable_actions, name) ->
        state

      MapSet.member?(@partial_actions, name) ->
        %{
          state
          | artifact:
              add_diagnostic(
                state.artifact,
                :partial,
                :advanced_action,
                "#{inspect(name)} is inspect-only in the first machine editor",
                section,
                meta[:line],
                meta[:column]
              )
        }

      name in [:callback, :foreign] ->
        %{
          state
          | artifact:
              add_diagnostic(
                state.artifact,
                :partial,
                :escape_hatch_action,
                "#{inspect(name)} is localized but inspect-only in v1",
                section,
                meta[:line],
                meta[:column]
              )
        }

      true ->
        %{
          state
          | artifact:
              add_diagnostic(
                state.artifact,
                :rejected,
                :unsupported_action,
                "unsupported action #{inspect(name)}",
                section,
                meta[:line],
                meta[:column]
              )
        }
    end
  end

  defp editable_hardware_ref?([value]), do: editable_literal_ast?(value)
  defp editable_hardware_ref?(_), do: false

  defp editable_literal_ast?(value), do: Macro.quoted_literal?(value)

  defp maybe_flag_invalid_transition_form(state, _meta, rest) do
    case split_do_args(rest) do
      {:ok, _prefix, _body} ->
        state

      :error ->
        %{
          state
          | artifact:
              add_diagnostic(
                state.artifact,
                :rejected,
                :invalid_transition_form,
                "transition must use `do ... end` form",
                :transitions,
                nil,
                nil
              )
        }
    end
  end

  defp split_do_args(args) when is_list(args) do
    case Enum.split(args, -1) do
      {prefix, [[do: body]]} -> {:ok, prefix, body}
      _ -> :error
    end
  end

  defp split_do_args(_), do: :error

  defp to_forms({:__block__, _, forms}), do: forms
  defp to_forms(nil), do: []
  defp to_forms(form), do: [form]

  defp finalize(%MachineArtifact{} = artifact) do
    compatibility =
      cond do
        Enum.any?(artifact.diagnostics, &(&1.classification == :rejected)) ->
          :not_visually_editable

        Enum.any?(artifact.diagnostics, &(&1.classification == :partial)) ->
          :partially_representable

        true ->
          :fully_editable
      end

    %{artifact | compatibility: compatibility, diagnostics: Enum.reverse(artifact.diagnostics)}
  end

  defp rejected_free?(artifact) do
    not Enum.any?(artifact.diagnostics, &(&1.classification == :rejected))
  end

  defp partial_present?(artifact) do
    Enum.any?(artifact.diagnostics, &(&1.classification == :partial))
  end

  defp add_diagnostic(artifact, classification, code, message, section, line, column) do
    diagnostic = diagnostic(classification, code, message, section, line, column)
    %{artifact | diagnostics: [diagnostic | artifact.diagnostics]}
  end

  defp diagnostic(classification, code, message, section, line, column) do
    %MachineDiagnostic{
      classification: classification,
      code: code,
      message: message,
      section: section,
      line: line,
      column: column
    }
  end
end
