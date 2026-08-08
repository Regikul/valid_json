defmodule ValidJsonBench.Profile do
  @moduledoc false

  @default_iterations 1_000
  @default_warmup 200
  @default_top 25

  def run do
    ensure_tprof!()
    ValidJsonBench.print_metadata()
    case_name = System.get_env("PROFILE_CASE", "nested_object")
    contexts = ValidJsonBench.setup!("exact:" <> case_name)

    dialect =
      env_enum!("PROFILE_DIALECT", "draft202012", %{
        "draft6" => :draft6,
        "draft202012" => :draft202012
      })

    scenario = scenario!(contexts, dialect, case_name)
    validity = env_enum!("PROFILE_VALIDITY", "valid", %{"valid" => :valid, "invalid" => :invalid})

    format =
      env_enum!("PROFILE_FORMAT", "flag", %{
        "flag" => :flag,
        "basic" => :basic,
        "detailed" => :detailed,
        "verbose" => :verbose
      })

    layer =
      env_enum!("PROFILE_LAYER", "full", %{
        "full" => :full,
        "lookup" => :lookup,
        "core" => :core,
        "eval" => :eval,
        "output" => :output
      })

    types = profile_types(System.get_env("PROFILE_TYPE", "all"))
    iterations = env_positive_integer!("PROFILE_ITERATIONS", @default_iterations)
    warmup = env_non_negative_integer!("PROFILE_WARMUP", @default_warmup)
    top = env_positive_integer!("PROFILE_TOP", @default_top)
    data = Map.fetch!(scenario, validity)

    {:ok, compiled} =
      :valid_json_store_manager.lookup(:valid_json, scenario.valid_json_uri)

    {:ok, eval_result} = :valid_json_eval.run(compiled, data, format)

    operation = operation(layer, scenario.valid_json_uri, compiled, data, format, eval_result)
    expected = validity == :valid
    assert_verdict!(layer, operation.(), expected)
    repeat(operation, warmup)

    patterns = valid_json_patterns()

    IO.puts("\nProfile configuration")
    IO.puts("  dialect: #{dialect}")
    IO.puts("  case: #{scenario.name}")
    IO.puts("  validity: #{validity}")
    IO.puts("  format: #{format}")
    IO.puts("  layer: #{layer}")
    IO.puts("  iterations: #{iterations}")
    IO.puts("  warmup: #{warmup}")
    IO.puts("  traced modules: #{length(patterns)}")

    Enum.each(types, fn type ->
      profile(type, operation, iterations, patterns, top)
    end)
  end

  defp operation(:full, uri, _compiled, data, format, _eval_result) do
    fn -> :valid_json.validate(uri, data, [{:output, format}]) end
  end

  defp operation(:lookup, uri, _compiled, _data, _format, _eval_result) do
    fn -> :valid_json_store_manager.lookup(:valid_json, uri) end
  end

  defp operation(:core, _uri, compiled, data, format, _eval_result) do
    fn -> :valid_json_core.validate(compiled, data, [{:output, format}]) end
  end

  defp operation(:eval, _uri, compiled, data, format, _eval_result) do
    fn -> :valid_json_eval.run(compiled, data, format) end
  end

  defp operation(:output, _uri, _compiled, _data, format, eval_result) do
    fn -> :valid_json_output.project(format, eval_result) end
  end

  defp assert_verdict!(:lookup, {:ok, _compiled}, _expected), do: :ok
  defp assert_verdict!(:eval, {:ok, result}, expected), do: assert_eval_verdict!(result, expected)
  defp assert_verdict!(:output, %{"valid" => expected}, expected), do: :ok
  defp assert_verdict!(_layer, {:ok, %{"valid" => expected}}, expected), do: :ok

  defp assert_verdict!(layer, result, expected) do
    raise "#{layer} returned #{inspect(result)}, expected valid=#{expected}"
  end

  # eval_result is intentionally opaque outside valid_json. element(2) is the
  # `valid` field of the record and is used only by this local benchmark check.
  defp assert_eval_verdict!(result, expected)
       when is_tuple(result) and tuple_size(result) == 5 and elem(result, 0) == :eval_result and
              elem(result, 1) == expected,
       do: :ok

  defp assert_eval_verdict!(result, expected) do
    raise "eval returned #{inspect(result)}, expected valid=#{expected}"
  end

  defp profile(type, operation, iterations, patterns, top) do
    IO.puts("\n#{String.duplicate("=", 78)}")
    IO.puts("tprof #{type}")
    IO.puts(String.duplicate("=", 78))

    {:ok, raw_profile} =
      :tprof.profile(
        fn -> repeat(operation, iterations) end,
        %{
          type: type,
          pattern: patterns,
          report: :return,
          set_on_spawn: false,
          timeout: :infinity
        }
      )

    %{all: {^type, total, lines}} =
      :tprof.inspect(raw_profile, :total, {:measurement, :descending})

    print_summary(type, total, iterations)
    print_lines(type, Enum.take(lines, top), iterations)
  end

  defp print_summary(:call_time, total, iterations) do
    IO.puts("Traced self time: #{format_number(total / iterations, 2)} us/op")
  end

  defp print_summary(:call_memory, total, iterations) do
    words = total / iterations
    bytes = words * :erlang.system_info(:wordsize)

    IO.puts(
      "Traced heap allocation: #{format_number(words, 2)} words/op (#{format_number(bytes, 2)} B/op)"
    )
  end

  defp print_summary(:call_count, total, iterations) do
    IO.puts("Traced calls: #{format_number(total / iterations, 2)} calls/op")
  end

  defp print_lines(type, lines, iterations) do
    IO.puts("FUNCTION\tCALLS/OP\t#{measurement_label(type)}/OP\tPER CALL\tPERCENT")

    Enum.each(lines, fn {module, {function, arity}, calls, measurement, per_call, percent} ->
      mfa = "#{module}:#{function}/#{arity}"

      IO.puts(
        Enum.join(
          [
            mfa,
            format_number(calls / iterations, 2),
            format_number(measurement / iterations, 2),
            format_number(per_call, 2),
            format_number(percent, 2)
          ],
          "\t"
        )
      )
    end)
  end

  defp measurement_label(:call_time), do: "US"
  defp measurement_label(:call_memory), do: "WORDS"
  defp measurement_label(:call_count), do: "CALLS"

  defp repeat(_operation, 0), do: :ok

  defp repeat(operation, remaining) do
    _result = operation.()
    repeat(operation, remaining - 1)
  end

  defp valid_json_patterns do
    :code.all_loaded()
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(fn module ->
      module
      |> Atom.to_string()
      |> String.starts_with?("valid_json")
    end)
    |> Enum.sort()
    |> Enum.map(&{&1, :_, :_})
  end

  defp scenario!(contexts, dialect, name) do
    case Enum.find(Map.fetch!(contexts, dialect), &(Atom.to_string(&1.name) == name)) do
      nil ->
        available =
          contexts
          |> Map.fetch!(dialect)
          |> Enum.map_join(", ", &Atom.to_string(&1.name))

        raise "unknown PROFILE_CASE=#{inspect(name)}; available: #{available}"

      scenario ->
        scenario
    end
  end

  defp profile_types("all"), do: [:call_count, :call_memory, :call_time]
  defp profile_types("count"), do: [:call_count]
  defp profile_types("call_count"), do: [:call_count]
  defp profile_types("memory"), do: [:call_memory]
  defp profile_types("call_memory"), do: [:call_memory]
  defp profile_types("time"), do: [:call_time]
  defp profile_types("call_time"), do: [:call_time]

  defp profile_types(value) do
    raise "unknown PROFILE_TYPE=#{inspect(value)}; expected all, count, memory, or time"
  end

  defp env_enum!(name, default, values) do
    value = System.get_env(name, default)

    case Map.fetch(values, value) do
      {:ok, parsed} ->
        parsed

      :error ->
        raise "unknown #{name}=#{inspect(value)}; expected one of #{inspect(Map.keys(values))}"
    end
  end

  defp env_positive_integer!(name, default) do
    case env_integer!(name, default) do
      value when value > 0 -> value
      value -> raise "#{name} must be positive, got #{value}"
    end
  end

  defp env_non_negative_integer!(name, default) do
    case env_integer!(name, default) do
      value when value >= 0 -> value
      value -> raise "#{name} must be non-negative, got #{value}"
    end
  end

  defp env_integer!(name, default) do
    value = System.get_env(name, Integer.to_string(default))

    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> raise "#{name} must be an integer, got #{inspect(value)}"
    end
  end

  defp format_number(number, _decimals) when is_integer(number), do: Integer.to_string(number)

  defp format_number(number, decimals) do
    :erlang.float_to_binary(number * 1.0, decimals: decimals)
  end

  # Minimal OTP installations do not necessarily put the tools application on
  # the boot code path even when it is installed. Locate it under the active
  # runtime instead of relying on a machine-specific absolute path.
  defp ensure_tprof! do
    case :code.ensure_loaded(:tprof) do
      {:module, :tprof} ->
        :ok

      {:error, :nofile} ->
        root = :code.root_dir() |> List.to_string()

        case Path.wildcard(Path.join([root, "lib", "tools-*", "ebin"])) do
          [tools_ebin] ->
            true = :code.add_patha(String.to_charlist(tools_ebin))
            {:module, :tprof} = :code.ensure_loaded(:tprof)
            :ok

          paths ->
            raise "cannot locate one OTP tools ebin directory, found: #{inspect(paths)}"
        end
    end
  end
end

ValidJsonBench.Profile.run()
