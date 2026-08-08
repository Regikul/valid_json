defmodule ValidJsonBench do
  @moduledoc false

  defmodule Scenario do
    @moduledoc false
    defstruct [:name, :schema, :valid, :invalid, :valid_json_uri, :jsonschex]
  end

  @draft6_uri "http://json-schema.org/draft-06/schema#"
  @draft202012_uri "https://json-schema.org/draft/2020-12/schema"
  @object_sizes [10, 100, 1_000]

  def setup!(case_filter \\ "all") do
    Enum.each([:jesse, :valid_json, :jsonschex], fn app ->
      {:ok, _started} = Application.ensure_all_started(app)
    end)

    %{
      draft6: prepare!(:draft6, case_filter),
      draft202012: prepare!(:draft202012, case_filter)
    }
  end

  def verify!(contexts) do
    Enum.each(contexts.draft6, &verify_draft6!/1)
    Enum.each(contexts.draft202012, &verify_draft202012!/1)
    :ok
  end

  def comparison_inputs(contexts, dialect, validity, case_filter \\ "all") do
    contexts
    |> Map.fetch!(dialect)
    |> Enum.filter(&selected?(&1.name, case_filter))
    |> Map.new(fn scenario ->
      data = Map.fetch!(scenario, validity)
      expected = validity == :valid

      {"#{scenario.name}/#{validity}",
       %{
         name: scenario.name,
         schema: scenario.schema,
         data: data,
         expected: expected,
         valid_json_uri: scenario.valid_json_uri,
         jsonschex: scenario.jsonschex
       }}
    end)
  end

  def all_inputs(contexts, dialect, case_filter \\ "all") do
    valid = comparison_inputs(contexts, dialect, :valid, case_filter)
    invalid = comparison_inputs(contexts, dialect, :invalid, case_filter)
    Map.merge(valid, invalid)
  end

  def jesse_diagnostic_inputs(contexts, case_filter \\ "all") do
    contexts
    |> comparison_inputs(:draft6, :invalid, case_filter)
    |> Map.reject(fn {_label, input} -> input.name == :composition end)
  end

  def valid_json_options(%{expected: true}), do: [{:output, :flag}]
  def valid_json_options(%{expected: false}), do: [{:output, :basic}]

  def print_metadata do
    IO.puts("Runtime metadata")
    IO.puts("  OTP: #{:erlang.system_info(:otp_release)}")
    IO.puts("  ERTS: #{:erlang.system_info(:version)}")
    IO.puts("  Elixir: #{System.version()}")
    IO.puts("  schedulers_online: #{:erlang.system_info(:schedulers_online)}")
    IO.puts("  benchmark: #{revision(benchmark_repo_root())}")
    IO.puts("  valid_json: #{revision(valid_json_root())}")
    IO.puts("  jesse: #{revision(Path.join(deps_root(), "jesse"))}")
    IO.puts("  jsonschex: #{revision(Path.join(deps_root(), "jsonschex"))}")
  end

  defp verify_draft6!(scenario) do
    Enum.each([{:valid, true}, {:invalid, false}], fn {sample, expected} ->
      data = Map.fetch!(scenario, sample)

      assert_verdict!(
        "Jesse #{scenario.name}/#{sample}",
        expected,
        jesse_verdict(:jesse.validate_with_schema(scenario.schema, data, []))
      )

      if scenario.name != :composition do
        assert_verdict!(
          "Jesse diagnostics #{scenario.name}/#{sample}",
          expected,
          jesse_verdict(
            :jesse.validate_with_schema(scenario.schema, data, [
              {:allowed_errors, :infinity}
            ])
          )
        )
      end

      verify_valid_json!(scenario, sample, data, expected)
    end)
  end

  defp verify_draft202012!(scenario) do
    Enum.each([{:valid, true}, {:invalid, false}], fn {sample, expected} ->
      data = Map.fetch!(scenario, sample)

      assert_verdict!(
        "JSONSchex #{scenario.name}/#{sample}",
        expected,
        jsonschex_verdict(JSONSchex.validate(scenario.jsonschex, data))
      )

      verify_valid_json!(scenario, sample, data, expected)
    end)
  end

  defp verify_valid_json!(scenario, sample, data, expected) do
    Enum.each([:flag, :basic, :detailed, :verbose], fn format ->
      assert_verdict!(
        "valid_json hot/#{format} #{scenario.name}/#{sample}",
        expected,
        valid_json_verdict(
          :valid_json.validate(scenario.valid_json_uri, data, [{:output, format}])
        )
      )
    end)

    format = if expected, do: :flag, else: :basic

    assert_verdict!(
      "valid_json cold/#{format} #{scenario.name}/#{sample}",
      expected,
      valid_json_verdict(:valid_json.run_schema(scenario.schema, data, [{:output, format}]))
    )
  end

  defp assert_verdict!(_label, expected, expected), do: :ok

  defp assert_verdict!(label, expected, actual) do
    raise "#{label}: expected verdict #{inspect(expected)}, got #{inspect(actual)}"
  end

  defp jesse_verdict({:ok, _data}), do: true
  defp jesse_verdict({:error, _errors}), do: false

  defp jsonschex_verdict(:ok), do: true
  defp jsonschex_verdict({:error, _errors}), do: false

  defp valid_json_verdict({:ok, %{"valid" => verdict}}), do: verdict

  defp prepare!(dialect, case_filter) do
    dialect
    |> scenarios()
    |> Enum.filter(&selected?(&1.name, case_filter))
    |> Enum.map(fn scenario ->
      {:ok, [uri]} = :valid_json.add(scenario.schema)

      jsonschex =
        case dialect do
          :draft6 ->
            nil

          :draft202012 ->
            {:ok, compiled} = JSONSchex.compile(scenario.schema)
            compiled
        end

      %{scenario | valid_json_uri: uri, jsonschex: jsonschex}
    end)
  end

  defp scenarios(dialect) do
    [
      scalar_string(dialect),
      nested_object(dialect),
      array_case(dialect, :array_10, 10, 9),
      array_case(dialect, :array_100_first_error, 100, 0),
      array_case(dialect, :array_100_last_error, 100, 99),
      composition(dialect),
      recursive_ref(dialect)
    ] ++ object_scenarios(dialect)
  end

  defp object_scenarios(dialect) do
    sweeps =
      Enum.flat_map(@object_sizes, fn size ->
        [
          object_properties(dialect, size),
          object_additional(dialect, size),
          object_patterns(dialect, size)
        ]
      end)

    coverage =
      case dialect do
        :draft6 -> []
        :draft202012 -> Enum.map(@object_sizes, &object_unevaluated(dialect, &1))
      end

    sweeps ++
      coverage ++
      [
        object_property_names(dialect, 100),
        object_required(dialect, 100),
        object_dependent_required(dialect, 100),
        object_dependent_schemas(dialect, 100)
      ]
  end

  defp scalar_string(dialect) do
    scenario(
      dialect,
      :scalar_string,
      %{
        "type" => "string",
        "minLength" => 3,
        "maxLength" => 64,
        "pattern" => "^[a-z]+$"
      },
      String.duplicate("a", 32),
      "a!"
    )
  end

  defp nested_object(dialect) do
    body = %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "integer", "minimum" => 1},
        "name" => %{"type" => "string", "minLength" => 1},
        "enabled" => %{"type" => "boolean"},
        "address" => %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string", "minLength" => 2},
            "zip" => %{"type" => "string", "pattern" => "^[0-9]{6}$"}
          },
          "required" => ["city", "zip"],
          "additionalProperties" => false
        },
        "roles" => %{
          "type" => "array",
          "items" => %{"type" => "string", "minLength" => 2},
          "minItems" => 1,
          "uniqueItems" => true
        }
      },
      "required" => ["id", "name", "enabled", "address", "roles"],
      "additionalProperties" => false
    }

    valid = %{
      "id" => 42,
      "name" => "Ada",
      "enabled" => true,
      "address" => %{"city" => "London", "zip" => "123456"},
      "roles" => ["admin", "author"]
    }

    invalid = %{
      "id" => 0,
      "name" => "",
      "enabled" => "yes",
      "address" => %{"city" => "X", "zip" => "wrong", "extra" => true},
      "roles" => ["x", "x"],
      "unexpected" => 1
    }

    scenario(dialect, :nested_object, body, valid, invalid)
  end

  defp object_properties(dialect, size) do
    properties =
      Map.new(object_indexes(size), fn index ->
        {property_name(index), integer_schema()}
      end)

    scenario(
      dialect,
      object_name(:properties, size),
      %{
        "type" => "object",
        "properties" => properties,
        "additionalProperties" => false
      },
      integer_object(size),
      invalid_integer_object(size)
    )
  end

  defp object_additional(dialect, size) do
    scenario(
      dialect,
      object_name(:additional, size),
      %{
        "type" => "object",
        "additionalProperties" => integer_schema()
      },
      integer_object(size),
      invalid_integer_object(size)
    )
  end

  # A third of the properties matches no pattern and reaches
  # additionalProperties, a third matches one pattern, and a third matches two.
  # The same object therefore exercises all pattern dispatch outcomes while the
  # width sweep still exposes their common slope.
  defp object_patterns(dialect, size) do
    {valid, invalid} =
      Map.new(object_indexes(size), fn index ->
        {pattern_property_name(index), index}
      end)
      |> then(fn valid ->
        invalid = Map.new(valid, fn {name, _value} -> {name, "invalid"} end)
        {valid, invalid}
      end)

    body = %{
      "type" => "object",
      "patternProperties" => %{
        "^one-" => integer_schema(),
        "^two-" => integer_schema(),
        "-overlap$" => integer_schema()
      },
      "additionalProperties" => integer_schema()
    }

    scenario(dialect, object_name(:patterns, size), body, valid, invalid)
  end

  # Coverage crosses allOf before unevaluatedProperties consumes it. Named and
  # unnamed properties are interleaved so both the covered and unevaluated
  # paths scale with the object.
  defp object_unevaluated(dialect, size) do
    properties =
      Map.new(Enum.take_every(object_indexes(size), 2), fn index ->
        {property_name(index), integer_schema()}
      end)

    body = %{
      "type" => "object",
      "allOf" => [%{"properties" => properties}],
      "unevaluatedProperties" => integer_schema()
    }

    scenario(
      dialect,
      object_name(:unevaluated, size),
      body,
      integer_object(size),
      invalid_integer_object(size)
    )
  end

  defp object_property_names(dialect, size) do
    valid = integer_object(size)

    invalid =
      Map.new(object_indexes(size), fn index ->
        {"x#{index}", index}
      end)

    scenario(
      dialect,
      object_name(:property_names, size),
      %{
        "type" => "object",
        "propertyNames" => %{"pattern" => "^p[0-9]+$"}
      },
      valid,
      invalid
    )
  end

  defp object_required(dialect, size) do
    scenario(
      dialect,
      object_name(:required, size),
      %{
        "type" => "object",
        "required" => Enum.map(object_indexes(size), &property_name/1)
      },
      integer_object(size),
      %{}
    )
  end

  defp object_dependent_required(dialect, size) do
    dependencies =
      Map.new(object_indexes(size), fn index ->
        {trigger_name(index), [dependent_name(index)]}
      end)

    keyword = if dialect == :draft6, do: "dependencies", else: "dependentRequired"

    scenario(
      dialect,
      object_name(:dependent_required, size),
      %{"type" => "object", keyword => dependencies},
      dependency_object(size, true),
      dependency_object(size, false)
    )
  end

  defp object_dependent_schemas(dialect, size) do
    dependencies =
      Map.new(object_indexes(size), fn index ->
        {trigger_name(index), %{"required" => [dependent_name(index)]}}
      end)

    keyword = if dialect == :draft6, do: "dependencies", else: "dependentSchemas"

    scenario(
      dialect,
      object_name(:dependent_schemas, size),
      %{"type" => "object", keyword => dependencies},
      dependency_object(size, true),
      dependency_object(size, false)
    )
  end

  defp array_case(dialect, name, size, invalid_index) do
    item_schema = %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "integer", "minimum" => 0},
        "label" => %{"type" => "string", "minLength" => 3},
        "active" => %{"type" => "boolean"}
      },
      "required" => ["id", "label", "active"],
      "additionalProperties" => false
    }

    body = %{
      "type" => "array",
      "items" => item_schema,
      "minItems" => 1,
      "uniqueItems" => true
    }

    valid =
      Enum.map(0..(size - 1), fn index ->
        %{"id" => index, "label" => "item-#{index}", "active" => rem(index, 2) == 0}
      end)

    invalid =
      List.update_at(valid, invalid_index, fn item ->
        %{item | "id" => -1, "label" => "x", "active" => "yes"}
      end)

    scenario(dialect, name, body, valid, invalid)
  end

  defp composition(dialect) do
    body = %{
      "allOf" => [
        %{
          "type" => "object",
          "properties" => %{
            "version" => %{"const" => 1},
            "payload" => %{
              "oneOf" => [
                %{
                  "type" => "object",
                  "properties" => %{"count" => %{"type" => "integer", "minimum" => 1}},
                  "required" => ["count"],
                  "additionalProperties" => false
                },
                %{
                  "type" => "object",
                  "properties" => %{"text" => %{"type" => "string", "minLength" => 3}},
                  "required" => ["text"],
                  "additionalProperties" => false
                }
              ]
            },
            "tags" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "contains" => %{"const" => "primary"}
            }
          },
          "required" => ["version", "payload", "tags"],
          "additionalProperties" => false
        },
        %{"not" => %{"properties" => %{"tags" => %{"maxItems" => 0}}}}
      ]
    }

    valid = %{
      "version" => 1,
      "payload" => %{"count" => 12},
      "tags" => ["primary", "stable"]
    }

    invalid = %{
      "version" => 2,
      "payload" => %{"count" => 0, "text" => "x"},
      "tags" => ["secondary", "experimental"]
    }

    scenario(dialect, :composition, body, valid, invalid)
  end

  defp recursive_ref(dialect) do
    body = %{
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "integer"},
        "children" => %{
          "type" => "array",
          "items" => %{"$ref" => "#"}
        }
      },
      "required" => ["value", "children"],
      "additionalProperties" => false
    }

    valid = tree(3, 3, 1)
    invalid = corrupt_last_leaf(valid, 3)
    scenario(dialect, :recursive_ref, body, valid, invalid)
  end

  defp scenario(dialect, name, body, valid, invalid) do
    schema =
      Map.merge(body, %{
        "$schema" => dialect_uri(dialect),
        "$id" => "https://bench.invalid/#{dialect}/#{name}"
      })

    %Scenario{name: name, schema: schema, valid: valid, invalid: invalid}
  end

  defp tree(0, _width, value), do: %{"value" => value, "children" => []}

  defp tree(depth, width, value) do
    children = Enum.map(1..width, &tree(depth - 1, width, value * 10 + &1))
    %{"value" => value, "children" => children}
  end

  defp corrupt_last_leaf(node, 0), do: %{node | "value" => "not-an-integer"}

  defp corrupt_last_leaf(node, depth) do
    children = List.update_at(node["children"], -1, &corrupt_last_leaf(&1, depth - 1))
    %{node | "children" => children}
  end

  defp integer_schema, do: %{"type" => "integer"}

  defp integer_object(size) do
    Map.new(object_indexes(size), fn index ->
      {property_name(index), index}
    end)
  end

  defp invalid_integer_object(size) do
    Map.new(object_indexes(size), fn index ->
      {property_name(index), "invalid"}
    end)
  end

  defp dependency_object(size, include_dependents) do
    triggers =
      Map.new(object_indexes(size), fn index ->
        {trigger_name(index), true}
      end)

    if include_dependents do
      Map.merge(
        triggers,
        Map.new(object_indexes(size), fn index ->
          {dependent_name(index), true}
        end)
      )
    else
      triggers
    end
  end

  defp pattern_property_name(index) do
    case rem(index, 3) do
      0 -> "plain-#{index}"
      1 -> "one-#{index}"
      2 -> "two-#{index}-overlap"
    end
  end

  defp property_name(index), do: "p#{index}"
  defp trigger_name(index), do: "trigger#{index}"
  defp dependent_name(index), do: "dependent#{index}"

  defp object_indexes(size), do: 0..(size - 1)

  defp object_name(kind, size), do: String.to_atom("object_#{kind}_#{size}")

  defp selected?(_name, "all"), do: true
  defp selected?(name, "exact:" <> expected), do: Atom.to_string(name) == expected
  defp selected?(name, filter), do: String.contains?(Atom.to_string(name), filter)

  defp dialect_uri(:draft6), do: @draft6_uri
  defp dialect_uri(:draft202012), do: @draft202012_uri

  defp revision(path) do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: path, stderr_to_stdout: true) do
      {revision, 0} ->
        suffix =
          case System.cmd("git", ["status", "--porcelain"], cd: path, stderr_to_stdout: true) do
            {"", 0} -> ""
            {_changes, 0} -> "-dirty"
            {_error, _status} -> "-unknown"
          end

        String.trim(revision) <> suffix

      {_error, _status} ->
        "unknown"
    end
  end

  defp bench_root, do: Path.expand("..", __DIR__)
  defp deps_root, do: Path.join(bench_root(), "deps")
  defp benchmark_repo_root, do: Path.expand("..", bench_root())

  defp valid_json_root do
    System.get_env("VALID_JSON_PATH", "..")
    |> Path.expand(bench_root())
  end
end
