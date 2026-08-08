defmodule ValidJsonBench.CompactFormatter do
  @moduledoc false
  @behaviour Benchee.Formatter

  @impl true
  def format(suite, _options) do
    header =
      "BENCH_RESULT\tinput\tjob\taverage_ns\tmedian_ns\tips\tmemory_bytes\treductions\n"

    rows =
      Enum.map(suite.scenarios, fn scenario ->
        runtime = scenario.run_time_data.statistics
        memory = optional_average(scenario.memory_usage_data.statistics)
        reductions = optional_average(scenario.reductions_data.statistics)

        [
          "BENCH_RESULT\t",
          scenario.input_name,
          "\t",
          scenario.job_name,
          "\t",
          number(runtime.average),
          "\t",
          number(runtime.median),
          "\t",
          number(runtime.ips),
          "\t",
          memory,
          "\t",
          reductions,
          "\n"
        ]
      end)

    [header | rows]
  end

  @impl true
  def write(output, _options) do
    IO.write(output)
    :ok
  end

  defp optional_average(%{sample_size: 0}), do: "-"
  defp optional_average(statistics), do: number(statistics.average)

  defp number(value) when is_integer(value), do: Integer.to_string(value)
  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
end
