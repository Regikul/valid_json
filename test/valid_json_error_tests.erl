%% Текст ошибки проверяется слабо: машинный контракт — это reason и location,
%% а формулировка остаётся политикой реализации и меняется свободно. Проверяется
%% только то, что текст строится, называет локацию и упоминает виновника.
-module(valid_json_error_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

format_test_() ->
    [?_assert(contains(format({bad_keyword_value, null}, {anonymous, <<"/maximum">>}),
                       <<"#/maximum">>)),
     %% У названного resource в локации остаётся его URI.
     ?_assert(contains(format({bad_keyword_value, 1}, {<<"https://example.com/s">>, <<"/type">>}),
                       <<"https://example.com/s#/type">>)),
     %% Причина от re структуры не имеет, но печататься обязана.
     ?_assertMatch(<<_:8, _/binary>>,
                   format({bad_pattern, {"missing )", 1}}, {anonymous, <<"/pattern">>})),
     ?_assert(contains(format({misplaced_keyword, <<"$schema">>},
                              {anonymous, <<"/properties/a/$schema">>}),
                       <<"$schema">>))].

%% У ошибки регистрации локации нет, и текст обходится без неё.
store_reason_test_() ->
    [?_assert(contains(format(invalid_uri, undefined), <<"URI">>)),
     ?_assert(contains(format(invalid_percent_encoding, undefined), <<"percent">>)),
     ?_assert(contains(format(relative_uri_without_base, undefined), <<"base">>)),
     ?_assert(contains(format({unknown_dialect,
                               <<"https://example.com/dialect">>}, undefined),
                       <<"https://example.com/dialect">>)),
     ?_assert(contains(format({name_taken, <<"https://example.com/schema">>}, undefined),
                       <<"https://example.com/schema">>)),
     ?_assert(contains(format({referenced_by, <<"https://example.com/leaf">>,
                               [<<"https://example.com/root">>]}, undefined),
                       <<"https://example.com/root">>))].

reference_reason_test_() ->
    Target = {<<"https://example.com/schema">>, <<"/$defs/value">>},
    [?_assert(contains(format(unresolved_anchor, {anonymous, <<"/$ref">>}),
                       <<"anchor">>)),
     ?_assert(contains(format({dangling_ref, Target}, {anonymous, <<"/$ref">>}),
                       <<"https://example.com/schema#/$defs/value">>)),
     ?_assert(contains(format({non_schema_target, Target},
                              {anonymous, <<"/$ref">>}),
                       <<"not a schema">>)),
     ?_assert(contains(format({unknown_document,
                               <<"https://example.com/missing">>},
                              {anonymous, <<"/$ref">>}),
                       <<"https://example.com/missing">>))].

metaschema_reason_test_() ->
    [?_assert(contains(format(schema_invalid, {anonymous, <<>>}),
                       <<"meta-schema">>)),
     ?_assert(contains(format({unrecognized_vocabulary,
                               <<"https://example.com/vocab">>}, {anonymous, <<>>}),
                       <<"https://example.com/vocab">>)),
     ?_assert(contains(format(core_vocabulary_missing, {anonymous, <<>>}),
                       <<"Core">>)),
     ?_assert(contains(format({metaschema_evaluation_failed,
                               <<"https://example.com/meta">>,
                               {no_progress, {anonymous, <<"/$ref">>}}},
                              {anonymous, <<>>}),
                       <<"https://example.com/meta">>))].

%% Ошибка вычисления печатается тем же входом, что и ошибка схемы: у неё есть
%% локация, и текст её называет.
eval_error_test_() ->
    Text = iolist_to_binary(
             valid_json_error:format_error({no_progress, {anonymous, <<"/$ref">>}})),
    [?_assert(contains(Text, <<"#/$ref">>)),
     ?_assert(contains(Text, <<"cycle">>))].

%% Каталог причин читается из самого типа, а не переписывается сюда руками:
%% текст обязан быть у каждой причины, и новая не должна проскочить мимо теста.
%% Проверка появилась не от хорошей жизни — `misplaced_keyword` уже полежала в
%% каталоге без формулировки, и вызывающий падал, когда пробовал её напечатать.
catalog_test_() ->
    Samples = samples(),
    [?_assertEqual(lists:sort(catalog()), lists:sort(maps:keys(Samples)))
     | [{lists:flatten(io_lib:format("~p", [Tag])),
         ?_assertMatch(<<_:8, _/binary>>, format(Reason, {anonymous, <<"/x">>}))}
        || {Tag, Reason} <- maps:to_list(Samples)]].

%% Тип объявлен в valid_json_core.hrl и попадает в abstract code каждого
%% модуля, который его включил. Читаем его у valid_json_error: полноту
%% проверяем как раз у него.
catalog() ->
    {ok, {_Module, [{abstract_code, {_Version, Forms}}]}} =
        beam_lib:chunks(code:which(valid_json_error), [abstract_code]),
    [{type, _Line, union, Members}] =
        [Type || {attribute, _, type, {reason, Type, []}} <- Forms],
    [tag(Member) || Member <- Members].

%% Причина без аргументов — сам атом, причина с аргументами — тег и их число.
tag({atom, _Line, Reason}) ->
    Reason;
tag({type, _Line, tuple, [{atom, _, Tag} | Args]}) ->
    {Tag, length(Args)}.

-spec samples() -> #{term() => reason()}.
samples() ->
    Target = {<<"https://example.com/schema">>, <<"/$defs/value">>},
    #{invalid_uri                  => invalid_uri,
      invalid_percent_encoding     => invalid_percent_encoding,
      relative_uri_without_base    => relative_uri_without_base,
      unresolved_anchor            => unresolved_anchor,
      core_vocabulary_missing      => core_vocabulary_missing,
      schema_invalid               => schema_invalid,
      unnamed_schema               => unnamed_schema,
      {dangling_ref, 1}            => {dangling_ref, Target},
      {non_schema_target, 1}       => {non_schema_target, Target},
      {unknown_document, 1}        => {unknown_document, <<"https://example.com/missing">>},
      {unknown_dialect, 1}         => {unknown_dialect, <<"https://example.com/dialect">>},
      {unrecognized_vocabulary, 1} => {unrecognized_vocabulary,
                                       <<"https://example.com/vocab">>},
      {misplaced_keyword, 1}       => {misplaced_keyword, <<"$schema">>},
      {name_taken, 1}              => {name_taken, <<"https://example.com/schema">>},
      {referenced_by, 2}           => {referenced_by, <<"https://example.com/leaf">>,
                                       [<<"https://example.com/root">>]},
      {metaschema_evaluation_failed, 2} =>
          {metaschema_evaluation_failed, <<"https://example.com/meta">>,
           {no_progress, {anonymous, <<"/$ref">>}}},
      {bad_keyword_value, 1}       => {bad_keyword_value, null},
      {bad_pattern, 1}             => {bad_pattern, {"missing )", 1}}}.

format(Reason, Location) ->
    iolist_to_binary(
      valid_json_error:format_error(#schema_error{reason = Reason, location = Location})).

contains(Text, Fragment) ->
    binary:match(Text, Fragment) =/= nomatch.
