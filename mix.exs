defmodule Membrane.FLACParser.Plugin.MixProject do
  use Mix.Project

  @version "0.5.0"
  @github_url "https://github.com/membraneframework/membrane_flac_parser_plugin"

  def project do
    [
      app: :membrane_flac_parser_plugin,
      version: @version,
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Plugin for parsing FLAC encoded audio stream",
      package: package(),
      name: "Membrane FlacParser plugin",
      source_url: @github_url,
      docs: docs(),
      homepage_url: "https://membraneframework.org",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.FLACParser],
      before_closing_head_tag: &sidebar_fix/1
    ]
  end

  defp sidebar_fix(_) do
    """
      <style type="text/css">
      .sidebar div.sidebar-header {
        margin: 15px;
      }
      </style>
    """
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp deps do
    [
      {:membrane_core, "~> 0.7.0"},
      {:membrane_caps_audio_flac, "~> 0.1.1"},
      {:crc, "~> 0.10.1"},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false},
      {:credo, "~> 1.4", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1.0", only: :dev, runtime: false},
      {:membrane_file_plugin, "~> 0.6.0", only: :test}
    ]
  end
end
