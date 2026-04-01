defmodule Ogol.HMI.Surface.Compiler do
  @moduledoc false

  alias Ogol.HMI.Surface

  defmodule Analysis do
    @moduledoc false

    @type classification :: :visual | :dsl_only | :invalid
    @type stage_status :: :ok | :error | :blocked | :ready | :unknown

    @type t :: %__MODULE__{
            source: String.t(),
            parse_status: stage_status(),
            classification: classification(),
            validation_status: stage_status(),
            compile_status: stage_status(),
            diagnostics: [String.t()],
            definition: Surface.t() | nil,
            runtime: Surface.Runtime.t() | nil
          }

    defstruct [
      :source,
      :parse_status,
      :classification,
      :validation_status,
      :compile_status,
      diagnostics: [],
      definition: nil,
      runtime: nil
    ]
  end

  @spec analyze(String.t()) :: Analysis.t()
  def analyze(source) when is_binary(source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, ast} ->
        if surface_candidate?(ast) do
          case compile_quoted(ast) do
            {:ok, definition, runtime} ->
              %Analysis{
                source: source,
                parse_status: :ok,
                classification: :visual,
                validation_status: :ok,
                compile_status: :ready,
                diagnostics: [],
                definition: definition,
                runtime: runtime
              }

            {:error, reason} ->
              %Analysis{
                source: source,
                parse_status: :ok,
                classification: :invalid,
                validation_status: :error,
                compile_status: :error,
                diagnostics: [reason]
              }
          end
        else
          %Analysis{
            source: source,
            parse_status: :ok,
            classification: :dsl_only,
            validation_status: :unknown,
            compile_status: :blocked,
            diagnostics: [
              "The draft parsed as Elixir, but it does not match the managed `use Ogol.HMI.Surface` subset."
            ]
          }
        end

      {:error, {line, error, token}} ->
        %Analysis{
          source: source,
          parse_status: :error,
          classification: :invalid,
          validation_status: :blocked,
          compile_status: :blocked,
          diagnostics: ["Parse error on line #{line}: #{inspect(error)} #{inspect(token)}"]
        }
    end
  end

  @spec ready?(Analysis.t()) :: boolean()
  def ready?(%Analysis{classification: :visual, compile_status: :ready}), do: true
  def ready?(_analysis), do: false

  @spec compile_source(String.t()) ::
          {:ok, Surface.t(), Surface.Runtime.t()} | {:error, Analysis.t()}
  def compile_source(source) when is_binary(source) do
    analysis = analyze(source)

    if ready?(analysis) do
      {:ok, analysis.definition, analysis.runtime}
    else
      {:error, analysis}
    end
  end

  defp compile_quoted(ast) do
    temp_module = temp_module()
    rewritten = rewrite_module_name(ast, temp_module)

    try do
      compiled = Code.compile_quoted(rewritten)

      case Enum.find(compiled, fn {module, _binary} ->
             function_exported?(module, :__ogol_hmi_surface__, 0) and
               function_exported?(module, :__ogol_hmi_surface_runtime__, 0)
           end) do
        {module, _binary} ->
          definition = Surface.definition(module)
          runtime = %{Surface.runtime(module) | module: nil}
          purge_modules(compiled)
          {:ok, definition, runtime}

        nil ->
          purge_modules(compiled)
          {:error, "Managed HMI source must define exactly one `use Ogol.HMI.Surface` module."}
      end
    rescue
      error ->
        {:error, Exception.message(error)}
    end
  end

  defp purge_modules(compiled) do
    Enum.each(compiled, fn {module, _binary} ->
      :code.purge(module)
      :code.delete(module)
    end)
  end

  defp surface_candidate?(ast) do
    ast
    |> defmodule_forms()
    |> Enum.count(&uses_hmi_surface?/1) == 1
  end

  defp defmodule_forms({:defmodule, _, _} = form), do: [form]

  defp defmodule_forms({:__block__, _, forms}),
    do: Enum.filter(forms, &match?({:defmodule, _, _}, &1))

  defp defmodule_forms(_other), do: []

  defp uses_hmi_surface?({:defmodule, _, [_name_ast, [do: body]]}) do
    body
    |> body_forms()
    |> Enum.any?(fn
      {:use, _, [{:__aliases__, _, [:Ogol, :HMI, :Surface]} | _]} -> true
      _ -> false
    end)
  end

  defp uses_hmi_surface?(_other), do: false

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(nil), do: []
  defp body_forms(form), do: [form]

  defp rewrite_module_name({:defmodule, meta, [_name_ast, body]}, module) do
    {:defmodule, meta, [alias_ast(module), body]}
  end

  defp rewrite_module_name({:__block__, meta, forms}, module) do
    {rewritten_forms, replaced?} =
      Enum.map_reduce(forms, false, fn
        {:defmodule, form_meta, [_name_ast, body]}, false ->
          {{:defmodule, form_meta, [alias_ast(module), body]}, true}

        form, replaced? ->
          {form, replaced?}
      end)

    if replaced?, do: {:__block__, meta, rewritten_forms}, else: {:__block__, meta, forms}
  end

  defp rewrite_module_name(other, _module), do: other

  defp alias_ast(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.map(&String.to_atom/1)
    |> then(&{:__aliases__, [], &1})
  end

  defp temp_module do
    suffix = System.unique_integer([:positive])
    Module.concat(["Ogol", "HMI", "Surface", "StudioCompiled", "Draft#{suffix}"])
  end
end
