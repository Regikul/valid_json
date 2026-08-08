defmodule ValidJsonBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :valid_json_bench,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:valid_json, path: valid_json_path()},
      {:jesse,
       git: "https://github.com/for-GET/jesse.git",
       ref: "d06868f481b1bbbf3169aac6e41594f951b5e262"},
      {:jsonschex,
       git: "https://github.com/xinz/jsonschex.git",
       ref: "4ba3c8c335630d63de4326f7dade5cdf88e5d0ba"},
      {:benchee, "~> 1.5", only: :dev, runtime: false}
    ]
  end

  defp valid_json_path do
    System.get_env("VALID_JSON_PATH", "..")
    |> Path.expand(__DIR__)
  end
end
