defmodule Mix.Tasks.Test.BrowserIntegration do
  use Mix.Task

  @shortdoc "Runs browser integration tests"

  @moduledoc """
  Runs the browser integration lane.

      mix test.browser_integration
      mix test.browser_integration test/integration/playwright/playwright_hmi_studio_test.exs
      mix test.browser_integration --watch 250

  `--watch <delay>` runs Playwright headed and applies the given slow-motion delay
  in milliseconds. It also leaves the browser open after a successful script
  until you stop the command.
  """

  @impl true
  def run(args) do
    {watch_delay, forwarded_args} = extract_watch(args)

    env_overrides =
      case watch_delay do
        nil ->
          []

        delay ->
          [
            {"PLAYWRIGHT_HEADLESS", "false"},
            {"PLAYWRIGHT_SLOW_MO", Integer.to_string(delay)},
            {"PLAYWRIGHT_KEEP_OPEN", "true"}
          ]
      end

    previous_env =
      Enum.map(env_overrides, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(env_overrides, fn {key, value} -> System.put_env(key, value) end)

    try do
      Mix.Task.run("test", ["--only", "browser_integration" | browser_test_args(forwarded_args)])
    after
      restore_env(previous_env)
    end
  end

  defp browser_test_args(args) do
    if explicit_test_paths?(args) do
      args
    else
      args ++ ["test/integration/playwright"]
    end
  end

  defp extract_watch(args), do: extract_watch(args, nil, [])

  defp extract_watch([], watch_delay, acc), do: {watch_delay, Enum.reverse(acc)}

  defp extract_watch(["--watch", delay | rest], _watch_delay, acc) do
    extract_watch(rest, parse_delay!(delay), acc)
  end

  defp extract_watch(["--watch"], _watch_delay, _acc) do
    Mix.raise("--watch requires a delay in milliseconds")
  end

  defp extract_watch([arg | rest], watch_delay, acc) do
    extract_watch(rest, watch_delay, [arg | acc])
  end

  defp parse_delay!(value) do
    case Integer.parse(value) do
      {delay, ""} when delay >= 0 ->
        delay

      _other ->
        Mix.raise("--watch expects a non-negative integer delay, got: #{inspect(value)}")
    end
  end

  defp explicit_test_paths?(args) do
    Enum.any?(args, fn arg ->
      String.starts_with?(arg, "test/") or String.ends_with?(arg, "_test.exs")
    end)
  end

  defp restore_env(previous_env) do
    Enum.each(previous_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
