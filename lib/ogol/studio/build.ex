defmodule Ogol.Studio.Build do
  @moduledoc false

  alias Ogol.Studio.Build.Artifact

  @spec build(term(), module(), String.t()) ::
          {:ok, Artifact.t()} | {:error, %{diagnostics: [term()]}}
  def build(id, module, source) when is_atom(module) and is_binary(source) do
    :global.trans({__MODULE__, :build}, fn ->
      loaded_before_build? = Code.ensure_loaded?(module)

      build_path =
        Path.join(System.tmp_dir!(), "ogol_studio_build_#{System.unique_integer([:positive])}")

      source_path = Path.join(build_path, "generated.ex")
      beam_path = Path.join(build_path, "#{Atom.to_string(module)}.beam")
      File.mkdir_p!(build_path)
      File.write!(source_path, source)

      response =
        with_compiler_option(:ignore_module_conflict, true, fn ->
          Kernel.ParallelCompiler.compile_to_path(
            [source_path],
            build_path,
            return_diagnostics: true,
            max_concurrency: 1
          )
        end)
        |> normalize_compile_result(id, module, beam_path, source)

      maybe_unload_ephemeral_module(module, loaded_before_build?)
      File.rm_rf(build_path)
      response
    end)
  end

  def digest(source) when is_binary(source) do
    :crypto.hash(:sha256, source)
    |> Base.encode16(case: :lower)
  end

  defp normalize_diagnostics(%{
         compile_warnings: compile_warnings,
         runtime_warnings: runtime_warnings
       }) do
    compile_warnings ++ runtime_warnings
  end

  defp normalize_diagnostics(other) when is_list(other), do: other
  defp normalize_diagnostics(_other), do: []

  defp normalize_error_diagnostics(errors) when is_list(errors), do: errors
  defp normalize_error_diagnostics(other), do: [other]

  defp normalize_compile_result({:ok, modules, warnings_info}, id, module, beam_path, source) do
    if module in modules and File.exists?(beam_path) do
      diagnostics = normalize_diagnostics(warnings_info)
      beam = File.read!(beam_path)
      source_digest = digest(source)

      {:ok,
       %Artifact{
         id: id,
         module: module,
         beam: beam,
         source_digest: source_digest,
         diagnostics: diagnostics
       }}
    else
      {:error,
       %{
         diagnostics: [
           "compiled modules did not include expected #{inspect(module)}"
         ]
       }}
    end
  end

  defp normalize_compile_result(
         {:error, errors, warnings_info},
         _id,
         _module,
         _beam_path,
         _source
       ) do
    diagnostics =
      normalize_diagnostics(warnings_info) ++ normalize_error_diagnostics(errors)

    {:error, %{diagnostics: diagnostics}}
  end

  defp with_compiler_option(key, value, fun) when is_atom(key) and is_function(fun, 0) do
    previous = Code.get_compiler_option(key)
    Code.put_compiler_option(key, value)

    try do
      fun.()
    after
      Code.put_compiler_option(key, previous)
    end
  end

  defp maybe_unload_ephemeral_module(_module, true), do: :ok

  defp maybe_unload_ephemeral_module(module, false) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      :code.soft_purge(module)
      :code.purge(module)
      :code.delete(module)
    end

    :ok
  end
end
