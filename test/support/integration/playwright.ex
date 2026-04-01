defmodule Integration.Playwright do
  @moduledoc """
  Runs local Playwright scripts for browser integration tests.

  The script receives:

  - `page` - current Playwright page
  - `context` - test context map passed from Elixir
  - `expect` - Playwright expect helper

  Environment flags:

  - `PLAYWRIGHT_HEADLESS=false` to watch the browser
  - `PLAYWRIGHT_SLOW_MO=250` to slow interactions for debugging
  - `PLAYWRIGHT_PAUSE=true` to open Playwright inspector before the script runs
  """

  @runner_path Path.expand("../../../integration/playwright/runner.js", __DIR__)
  @timeout 30_000

  def available? do
    case MuonTrap.cmd("node", [@runner_path, "--check"],
           stderr_to_stdout: true,
           timeout: 15_000
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, "runner unavailable (exit #{status}): #{String.trim(output)}"}
    end
  end

  def run(script, context \\ %{}) do
    wait_for_server()

    context =
      cond do
        is_map(context) -> context
        Keyword.keyword?(context) -> Map.new(context)
        true -> %{}
      end

    unique = Integer.to_string(:erlang.unique_integer([:positive]))
    artifact_dir = Path.join(System.tmp_dir!(), "ogol_playwright_#{unique}")

    timeout = context[:timeout_ms] || @timeout

    payload = %{
      script: script,
      context: context,
      baseUrl: base_url(),
      artifactDir: artifact_dir
    }

    payload_path = Path.join(System.tmp_dir!(), "playwright_#{unique}.json")
    File.write!(payload_path, Jason.encode!(payload))

    try do
      case MuonTrap.cmd("node", [@runner_path, payload_path],
             stderr_to_stdout: true,
             timeout: timeout
           ) do
        {output, 0} ->
          {:ok, output}

        {output, status} ->
          {:error, %{status: status, output: String.trim(output), artifacts: artifact_dir}}
      end
    after
      File.rm(payload_path)
    end
  end

  def run!(script, context \\ %{}) do
    case run(script, context) do
      {:ok, _output} ->
        :ok

      {:error, %{status: status, output: output, artifacts: artifacts}} ->
        raise """
        Playwright script failed (exit #{status}):
        #{output}

        artifacts: #{artifacts}
        """
    end
  end

  defp wait_for_server(attempts \\ 50)

  defp wait_for_server(0) do
    uri = server_uri()
    raise "Server not available at #{uri.host}:#{uri.port}"
  end

  defp wait_for_server(attempts) do
    uri = server_uri()

    case :gen_tcp.connect(String.to_charlist(uri.host), uri.port, [], 100) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, _reason} ->
        Process.sleep(100)
        wait_for_server(attempts - 1)
    end
  end

  defp base_url do
    Application.get_env(:ogol, :playwright_base_url) || endpoint_base_url()
  end

  defp endpoint_base_url do
    config = Application.fetch_env!(:ogol, OgolWeb.Endpoint)
    url_config = Keyword.fetch!(config, :url)
    scheme = if Keyword.has_key?(config, :https), do: "https", else: "http"
    host = Keyword.fetch!(url_config, :host)
    port = Keyword.fetch!(url_config, :port)

    "#{scheme}://#{host}:#{port}"
  end

  defp server_uri do
    uri = URI.parse(base_url())
    host = uri.host || "127.0.0.1"
    port = uri.port || if uri.scheme == "https", do: 443, else: 80
    %URI{uri | host: host, port: port}
  end
end
