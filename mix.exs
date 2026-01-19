defmodule ExVrp.MixProject do
  use Mix.Project

  @version "0.1.0"
  @github_url "https://github.com/sephianl/ex_vrp"

  def project do
    [
      app: :ex_vrp,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      make_args: ["-j#{System.schedulers_online()}"],
      make_env: fn -> %{"FINE_INCLUDE_DIR" => Fine.include_dir()} end,

      # Hex
      description: "Elixir bindings for PyVRP - a state-of-the-art vehicle routing problem solver",
      package: package(),

      # Docs
      name: "ExVrp",
      docs: docs(),

      # Testing
      test_coverage: [tool: ExCoveralls],

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:mix]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExVrp.Application, []}
    ]
  end

  defp deps do
    [
      # NIF compilation
      {:elixir_make, "~> 0.8", runtime: false},
      {:fine, "~> 0.1.4"},
      {:nx, "~> 0.10"},

      # Testing
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:excoveralls, "~> 0.18", only: :test},

      # Benchmarking
      {:benchee, "~> 1.3", only: [:dev, :test]},
      {:jason, "~> 1.4", only: [:dev, :test]},

      # Mix check
      {:ex_check, "~> 0.16.0", only: [:dev, :test], runtime: false},
      # Static code analysis
      {:credo, ">= 0.0.0", only: [:dev], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:sobelow, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false},

      # Formatting
      {:styler, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Sephian"],
      licenses: ["MIT"],
      links: %{"GitHub" => @github_url},
      files: ~w(lib c_src priv mix.exs Makefile README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: @github_url,
      source_ref: "v#{@version}"
    ]
  end
end
