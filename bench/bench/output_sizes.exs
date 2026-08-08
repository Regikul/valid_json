case_filter = System.get_env("BENCH_CASE", "all")
contexts = ValidJsonBench.setup!(case_filter)
:ok = ValidJsonBench.verify!(contexts)

IO.puts("OUTPUT_SIZE\tinput\tformat\texternal_bytes")

contexts
|> ValidJsonBench.all_inputs(:draft202012)
|> Enum.sort_by(fn {name, _input} -> name end)
|> Enum.each(fn {name, input} ->
  Enum.each([:flag, :basic, :detailed, :verbose], fn format ->
    {:ok, output} =
      :valid_json.validate(input.valid_json_uri, input.data, [{:output, format}])

    IO.puts("OUTPUT_SIZE\t#{name}\t#{format}\t#{:erlang.external_size(output)}")
  end)
end)
