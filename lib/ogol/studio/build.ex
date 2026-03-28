defmodule Ogol.Studio.Build do
  @moduledoc false

  alias Ogol.Studio.Build.Artifact
  alias Ogol.Studio.ModuleStatusStore

  @spec build(term(), module(), String.t()) ::
          {:ok, Artifact.t()} | {:error, %{diagnostics: [term()]}}
  def build(id, module, source) when is_atom(module) and is_binary(source) do
    ModuleStatusStore.ensure_started()

    build_path =
      Path.join(System.tmp_dir!(), "ogol_studio_build_#{System.unique_integer([:positive])}")

    source_path = Path.join(build_path, "generated.ex")
    beam_path = Path.join(build_path, "#{Atom.to_string(module)}.beam")
    File.mkdir_p!(build_path)
    File.write!(source_path, source)

    result =
      Kernel.ParallelCompiler.compile_to_path(
        [source_path],
        build_path,
        return_diagnostics: true,
        max_concurrency: 1
      )

    response =
      case result do
        {:ok, modules, warnings_info} ->
          if module in modules and File.exists?(beam_path) do
            diagnostics = normalize_diagnostics(warnings_info)
            beam = File.read!(beam_path)
            source_digest = digest(source)
            ModuleStatusStore.record_build(id, source_digest)

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

        {:error, errors, warnings_info} ->
          diagnostics =
            normalize_diagnostics(warnings_info) ++ normalize_error_diagnostics(errors)

          {:error, %{diagnostics: diagnostics}}
      end

    File.rm_rf(build_path)
    response
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
end
