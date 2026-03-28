defmodule Ogol.MixProject do
  use Mix.Project

  def project do
    [
      app: :ogol,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      usage_rules: usage_rules()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Ogol.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "examples", "test/support"]
  defp elixirc_paths(_), do: ["lib", "examples"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:tidewave, "~> 0.5", only: [:dev]},
      {:ethercat, path: "../ethercat"},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.1"},
      {:plug_cowboy, "~> 2.8"},
      {:jason, "~> 1.4"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:muontrap, "~> 1.7", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.4.1", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:zoi, "~> 0.17"},
      {:spark, "~> 2.6"},
      {:usage_rules, "~> 1.2", only: :dev}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup"],
      "phx.routes": "phx.routes Ogol.HMIWeb.Router",
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind ogol_hmi", "esbuild ogol_hmi"],
      "assets.deploy": ["tailwind ogol_hmi --minify", "esbuild ogol_hmi --minify", "phx.digest"],
      "integration.setup": [
        "cmd --cd integration/playwright npm ci",
        "cmd --cd integration/playwright npx playwright install chromium"
      ]
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:elixir, :otp, :spark]
    ]
  end
end
