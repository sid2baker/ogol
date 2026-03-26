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
      usage_rules: usage_rules()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ethercat, path: "../ethercat"},
      {:spark, "~> 2.6"},
      {:usage_rules, "~> 1.2", only: :dev}
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:elixir, :otp, :spark]
    ]
  end
end
