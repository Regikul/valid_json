defmodule ValidJsonBench.Compare do
  @moduledoc false

  def run do
    ValidJsonBench.print_metadata()
    case_filter = System.get_env("BENCH_CASE", "all")
    contexts = ValidJsonBench.setup!(case_filter)
    :ok = ValidJsonBench.verify!(contexts)

    suite = System.get_env("BENCH_SUITE", "all")
    options = benchee_options()

    if suite in ["all", "jesse"], do: run_jesse(contexts, case_filter, options)
    if suite in ["all", "jsonschex"], do: run_jsonschex(contexts, case_filter, options)
    if suite in ["all", "output"], do: run_output_formats(contexts, case_filter, options)
  end

  defp run_jesse(contexts, case_filter, options) do
    inputs = ValidJsonBench.all_inputs(contexts, :draft6, case_filter)

    if map_size(inputs) == 0 do
      skip("Draft 6: Jesse", case_filter)
    else
      run_jesse(inputs, contexts, case_filter, options)
    end
  end

  defp run_jesse(inputs, contexts, case_filter, options) do
    heading("Draft 6: Jesse cold vs valid_json cold and hot; verdict-oriented")

    Benchee.run(
      %{
        "jesse/cold/default" => fn input ->
          :jesse.validate_with_schema(input.schema, input.data, [])
        end,
        "valid_json/cold/flag" => fn input ->
          :valid_json.run_schema(input.schema, input.data, [{:output, :flag}])
        end,
        "valid_json/hot/flag" => fn input ->
          :valid_json.validate(input.valid_json_uri, input.data, [{:output, :flag}])
        end
      },
      Keyword.put(options, :inputs, inputs)
    )

    diagnostic_inputs = ValidJsonBench.jesse_diagnostic_inputs(contexts, case_filter)

    heading("Draft 6 invalid: Jesse all errors vs valid_json basic")

    Benchee.run(
      %{
        "jesse/cold/all-errors" => fn input ->
          :jesse.validate_with_schema(input.schema, input.data, [
            {:allowed_errors, :infinity}
          ])
        end,
        "valid_json/cold/basic" => fn input ->
          :valid_json.run_schema(input.schema, input.data, [{:output, :basic}])
        end,
        "valid_json/hot/basic" => fn input ->
          :valid_json.validate(input.valid_json_uri, input.data, [{:output, :basic}])
        end
      },
      Keyword.put(options, :inputs, diagnostic_inputs)
    )
  end

  defp run_jsonschex(contexts, case_filter, options) do
    inputs = ValidJsonBench.all_inputs(contexts, :draft202012, case_filter)

    if map_size(inputs) == 0 do
      skip("Draft 2020-12: JSONSchex", case_filter)
    else
      run_jsonschex(inputs, options)
    end
  end

  defp run_jsonschex(inputs, options) do
    heading("Draft 2020-12 cold: compile and validate")

    Benchee.run(
      %{
        "jsonschex/cold" => fn input ->
          {:ok, compiled} = JSONSchex.compile(input.schema)
          JSONSchex.validate(compiled, input.data)
        end,
        "valid_json/cold" => fn input ->
          :valid_json.run_schema(
            input.schema,
            input.data,
            ValidJsonBench.valid_json_options(input)
          )
        end
      },
      Keyword.put(options, :inputs, inputs)
    )

    heading("Draft 2020-12 hot: precompiled schemas")

    Benchee.run(
      %{
        "jsonschex/hot" => fn input ->
          JSONSchex.validate(input.jsonschex, input.data)
        end,
        "valid_json/hot" => fn input ->
          :valid_json.validate(
            input.valid_json_uri,
            input.data,
            ValidJsonBench.valid_json_options(input)
          )
        end
      },
      Keyword.put(options, :inputs, inputs)
    )
  end

  defp run_output_formats(contexts, case_filter, options) do
    inputs = ValidJsonBench.all_inputs(contexts, :draft202012, case_filter)

    if map_size(inputs) == 0 do
      skip("valid_json Draft 2020-12 output formats", case_filter)
    else
      run_output_formats(inputs, options)
    end
  end

  defp run_output_formats(inputs, options) do
    heading("valid_json Draft 2020-12 hot output formats")

    jobs =
      Map.new(output_formats(), fn format ->
        {Atom.to_string(format),
         fn input ->
           :valid_json.validate(input.valid_json_uri, input.data, [{:output, format}])
         end}
      end)

    Benchee.run(jobs, Keyword.put(options, :inputs, inputs))
  end

  defp output_formats do
    available = %{
      "flag" => :flag,
      "basic" => :basic,
      "detailed" => :detailed,
      "verbose" => :verbose
    }

    System.get_env("BENCH_OUTPUT_FORMATS", "flag,basic,detailed,verbose")
    |> String.split(",", trim: true)
    |> Enum.map(fn name ->
      case Map.fetch(available, name) do
        {:ok, format} -> format
        :error -> raise "unknown BENCH_OUTPUT_FORMATS entry #{inspect(name)}"
      end
    end)
    |> Enum.uniq()
  end

  defp benchee_options do
    [
      warmup: env_integer("BENCH_WARMUP", 2),
      time: env_integer("BENCH_TIME", 5),
      memory_time: env_integer("BENCH_MEMORY_TIME", 2),
      reduction_time: env_integer("BENCH_REDUCTION_TIME", 2),
      formatters: formatters(),
      print: [fast_warning: false]
    ]
  end

  defp formatters do
    case System.get_env("BENCH_FORMAT", "console") do
      "compact" -> [ValidJsonBench.CompactFormatter]
      "console" -> [{Benchee.Formatters.Console, comparison: true}]
      format -> raise "unknown BENCH_FORMAT=#{inspect(format)}"
    end
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  defp heading(text) do
    IO.puts("\n#{String.duplicate("=", 78)}")
    IO.puts(text)
    IO.puts(String.duplicate("=", 78))
  end

  defp skip(section, case_filter) do
    IO.puts("\nSkipping #{section}: BENCH_CASE=#{inspect(case_filter)} has no matching inputs")
  end
end

ValidJsonBench.Compare.run()
