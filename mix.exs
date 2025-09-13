defmodule ReqLLM.MixProject do
  use Mix.Project

  def project do
    [
      app: :req_llm,
      version: "1.0.0-rc.1",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Dialyzer configuration
      dialyzer: [
        plt_add_apps: [:mix],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],

      # Package
      package: package(),

      # Documentation
      name: "ReqLLM",
      source_url: "https://github.com/agentjido/req_llm",
      homepage_url: "https://github.com/agentjido/req_llm",
      source_ref: "v1.0.0-rc.1",
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/getting-started.md",
          "guides/core-concepts.md",
          "guides/api-reference.md",
          "guides/data-structures.md",
          "guides/capability-testing.md",
          "guides/adding_a_provider.md"
        ],
        groups_for_extras: [
          Guides: ~r/guides\/.*/
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ReqLLM.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:typed_struct, "~> 0.3.0"},
      {:splode, "~> 0.2.3"},
      {:server_sent_events, "~> 0.2"},
      {:jido_keys, "~> 1.0"},

      # Dev/test dependencies
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", runtime: false},
      {:quokka, "~> 2.11", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      description: "Composable Elixir library for AI interactions built on Req",
      licenses: ["Apache-2.0"],
      maintainers: ["Mike Hostetler"],
      links: %{"GitHub" => "https://github.com/agentjido/req_llm"},
      files:
        ~w(lib priv mix.exs LICENSE CHANGELOG.md README.md usage-rules.md guides .formatter.exs)
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "dialyzer",
        "credo --strict"
      ],
      q: ["quality"]
    ]
  end
end
