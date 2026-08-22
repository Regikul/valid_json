%% Чистый registry: регистрация документов, два имени, upsert, batch atomicity,
%% удаление и встроенная immutable область.
-module(valid_json_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_resources.hrl").

%% Встроенные метасхемы поднимает дерево приложения, и без него компиляция
%% схемы не идёт.
ensure_app() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    ok.

eunit_wrapper_(Tests) ->
    {setup, fun ensure_app/0, {inparallel, Tests}}.

-define(BASE, <<"https://example.com/schemas/">>).
-define(BUILTIN, <<"https://json-schema.org/draft/2020-12/schema">>).

new_test_() ->
    [?_assertEqual(#store{base = ?BASE}, valid_json_store:new([{base_uri, ?BASE}])),
     %% `base_uri` проходит ту же URI normalization, что и имена документов.
     ?_assertEqual(#store{base = <<"http://example.com/schemas/">>},
                   valid_json_store:new([{base_uri,
                                          <<"HTTP://Example.COM:80/a/../schemas/">>}])),
     %% Hierarchical URI без authority тоже допустим.
     ?_assertEqual(#store{base = <<"file:/schemas/">>},
                   valid_json_store:new([{base_uri, <<"file:/schemas/">>}]))].

%% Завершающий слэш дописывается нормализацией: без него разрешение съело бы
%% последний сегмент имени.
trailing_slash_test_() ->
    [?_assertEqual(#store{base = <<"https://example.com/schemas/">>},
                   valid_json_store:new([{base_uri,
                                          <<"https://example.com/schemas">>}])),
     ?_assertEqual(#store{base = <<"https://example.com/">>},
                   valid_json_store:new([{base_uri, <<"https://example.com">>}])),
     ?_assertEqual({ok, <<"https://example.com/schemas/product/banana">>},
                   valid_json_store:resolve_name(
                     <<"product/banana">>,
                     valid_json_store:base(
                       valid_json_store:new([{base_uri,
                                              <<"https://example.com/schemas">>}]))))].

%% Реестр на один вызов компиляции имён не разрешает и `base_uri` не имеет.
temporary_test() ->
    ?assertEqual(anonymous, valid_json_store:base(valid_json_store:temporary())).

new_error_test_() ->
    %% Без `base_uri` реестру нечем называть документы, и это ошибка вызова.
    [?_assertError(badarg, valid_json_store:new([])),
     ?_assertError(badarg, valid_json_store:new([{base_uri, <<"relative/path">>}])),
     ?_assertError(badarg, valid_json_store:new([{base_uri, <<"urn:example:root">>}])),
     ?_assertError(badarg, valid_json_store:new([{base_uri,
                                                  <<"https://example.com/#x">>}])),
     %% Query дописать слэшем некуда, а разрешение его всё равно отбрасывает.
     ?_assertError(badarg, valid_json_store:new([{base_uri,
                                                  <<"https://example.com/s?x=1">>}])),
     ?_assertError(badarg, valid_json_store:new([{unknown, true}])),
     ?_assertError(badarg, valid_json_store:new(not_a_list))].

%% Без `$id` каноническое имя совпадает с именем регистрации. Сам JSON сохраняется как есть.
absolute_test() ->
    Json = #{<<"type">> => <<"integer">>},
    Uri = <<"https://example.com/integer">>,
    {ok, Uri, Store} = valid_json_store:add(valid_json_store:temporary(), Uri, Json),
    Expected = #document{registered = Uri, canonical = Uri, json = Json},
    ?assertEqual(Expected, valid_json_store:fetch(Uri, Store)).

%% Имя регистрации разрешается от `base_uri`, а корневой `$id` — от него самого.
%% Оба ключа указывают на один и тот же immutable document term.
canonical_test() ->
    Json = #{<<"$id">> => <<"../canonical/banana">>,
             <<"$defs">> => #{<<"embedded">> =>
                                   #{<<"$id">> => <<"embedded">>}}},
    {ok, Canonical, Store} =
        valid_json_store:add(valid_json_store:new([{base_uri, ?BASE}]),
                             <<"product/banana">>, Json),
    Registered = <<"https://example.com/schemas/product/banana">>,
    ?assertEqual(<<"https://example.com/schemas/canonical/banana">>, Canonical),
    RegisteredDocument = valid_json_store:fetch(Registered, Store),
    CanonicalDocument = valid_json_store:fetch(Canonical, Store),
    ?assertEqual(#document{registered = Registered, canonical = Canonical, json = Json},
                 RegisteredDocument),
    ?assert(RegisteredDocument =:= CanonicalDocument),
    %% Вложенный `$id` создаст resource при компиляции, но третьего имени
    %% document в store не образует.
    ?assertEqual(undefined,
                 valid_json_store:fetch(
                   <<"https://example.com/schemas/product/embedded">>, Store)).

normalization_test() ->
    Written = <<"HTTP://Example.COM:80/a/./b/../schema">>,
    Canonical = <<"http://example.com/a/schema">>,
    {ok, Canonical, Store} =
        valid_json_store:add(valid_json_store:temporary(), Written, true),
    ?assertMatch(#document{registered = Canonical, canonical = Canonical},
                 valid_json_store:fetch(Canonical, Store)),
    %% Исходное написание отдельным alias не хранится.
    ?assertEqual(undefined, valid_json_store:fetch(Written, Store)).

%% Первая ступень выводит имя из `$id` и отдаёт обычную пару: дальше реестру
%% всё равно, откуда имя взялось.
name_entries_test() ->
    Absolute = <<"https://example.com/self">>,
    Json = #{<<"$id">> => Absolute},
    ?assertEqual({ok, [{Absolute, Json}]},
                 valid_json_store:name_entries(valid_json_store:temporary(),
                                               [Json])),
    %% Относительный `$id` разрешается от базы хранилища: другой базы у такой
    %% схемы нет.
    Relative = #{<<"$id">> => <<"weight">>},
    ?assertEqual({ok, [{<<"https://example.com/schemas/weight">>, Relative}]},
                 valid_json_store:name_entries(
                   valid_json_store:new([{base_uri, ?BASE}]), [Relative])).

%% Не назвавшая себя схема дальше первой ступени не идёт: корень документа
%% обязан быть schema resource с абсолютным именем. Boolean отвергается по той
%% же причине — keywords он не несёт, и `$id` в нём быть не может.
name_entries_error_test_() ->
    Empty = valid_json_store:temporary(),
    [?_assertEqual({error, [entry_error(anonymous, unnamed_schema)]},
                   valid_json_store:name_entries(
                     Empty, [#{<<"type">> => <<"integer">>}])),
     ?_assertEqual({error, [entry_error(anonymous, unnamed_schema)]},
                   valid_json_store:name_entries(Empty, [true])),
     ?_assertEqual({error, [entry_error(anonymous, unnamed_schema)]},
                   valid_json_store:name_entries(Empty, [false])),
     ?_assertEqual({error, [entry_error(anonymous, {bad_keyword_value, 42})]},
                   valid_json_store:name_entries(Empty, [#{<<"$id">> => 42}])),
     ?_assertEqual({error, [entry_error(anonymous,
                                        {bad_keyword_value, <<"#anchor">>})]},
                   valid_json_store:name_entries(
                     Empty, [#{<<"$id">> => <<"#anchor">>}])),
     ?_assertEqual({error, [entry_error(anonymous, relative_uri_without_base)]},
                   valid_json_store:name_entries(Empty,
                                                 [#{<<"$id">> => <<"weight">>}])),
     %% Ошибки собираются все, как и на второй ступени.
     ?_assertEqual({error, [entry_error(anonymous, unnamed_schema),
                            entry_error(anonymous, {bad_keyword_value, 42})]},
                   valid_json_store:name_entries(
                     Empty, [true, #{<<"$id">> => <<"https://example.com/a">>},
                             #{<<"$id">> => 42}])),
     %% Пара сюда не ходит вовсе: имя у неё уже есть, и ступень эта не её.
     ?_assertError(function_clause,
                   valid_json_store:name_entries(
                     Empty, [{<<"https://example.com/a">>, true}])),
     ?_assertError(function_clause, valid_json_store:name_entries(Empty, [42])),
     ?_assertError(badarg, valid_json_store:name_entries(Empty, not_a_list))].

%% Обе ступени вместе: у документа, названного своим `$id`, оба имени совпадают,
%% потому что имя регистрации выведено из того же `$id`.
name_entries_and_add_test() ->
    Canonical = <<"https://example.com/self">>,
    Json = #{<<"$id">> => Canonical},
    Store0 = valid_json_store:temporary(),
    {ok, Entries} = valid_json_store:name_entries(Store0, [Json]),
    {ok, [Canonical], Store} = valid_json_store:add(Store0, Entries),
    ?assertEqual(#document{registered = Canonical,
                           canonical = Canonical,
                           json = Json},
                 valid_json_store:fetch(Canonical, Store)).

%% `$id` служит такому документу и именем регистрации, поэтому повтор — обычный
%% upsert.
name_entries_upsert_test() ->
    Canonical = <<"https://example.com/self">>,
    NewJson = #{<<"$id">> => Canonical, <<"const">> => 2},
    Store0 = valid_json_store:temporary(),
    {ok, [Canonical], Store1} =
        named_add(Store0, [#{<<"$id">> => Canonical, <<"const">> => 1}]),
    {ok, [Canonical], Store} = named_add(Store1, [NewJson]),
    ?assertMatch(#document{json = NewJson}, valid_json_store:fetch(Canonical, Store)).

%% Имя, занятое чужим документом, отвергается второй ступенью и называется уже
%% выведенным именем: `anonymous` остаётся только за тем, что упало до него.
name_entries_conflict_test() ->
    Registered = <<"https://example.com/registered">>,
    Taken = <<"https://example.com/taken">>,
    {ok, Taken, Store} =
        valid_json_store:add(valid_json_store:temporary(), Registered,
                             #{<<"$id">> => Taken}),
    ?assertEqual({error, [entry_error(Taken, {name_taken, Taken})]},
                 named_add(Store, [#{<<"$id">> => Taken}])).

registration_error_test_() ->
    Empty = valid_json_store:temporary(),
    [?_assertEqual(schema_error(relative_uri_without_base),
                   valid_json_store:add(Empty, <<"relative.json">>, true)),
     ?_assertEqual(schema_error(invalid_uri),
                   valid_json_store:add(Empty, <<"http://[::1">>, true)),
     ?_assertEqual(schema_error(invalid_uri),
                   valid_json_store:add(Empty, <<"https://example.com/s#anchor">>, true)),
     ?_assertEqual(schema_error({bad_keyword_value, 42}),
                   valid_json_store:add(Empty, <<"https://example.com/s">>,
                                        #{<<"$id">> => 42})),
     ?_assertEqual(schema_error({bad_keyword_value, <<"#anchor">>}),
                   valid_json_store:add(Empty, <<"https://example.com/s">>,
                                        #{<<"$id">> => <<"#anchor">>})),
     ?_assertEqual(schema_error(invalid_uri),
                   valid_json_store:add(Empty, <<"https://example.com/s">>,
                                        #{<<"$id">> => <<"bad%zz">>})),
     ?_assertEqual(schema_error(invalid_percent_encoding),
                   valid_json_store:add(Empty, <<"https://example.com/s#%zz">>, true))].

%% Повтор того же имени регистрации заменяет документ, меняет canonical alias и снимает
%% старое имя.
upsert_test() ->
    Registered = <<"https://example.com/registered">>,
    OldCanonical = <<"https://example.com/old">>,
    NewCanonical = <<"https://example.com/new">>,
    {ok, OldCanonical, OldStore} =
        valid_json_store:add(valid_json_store:temporary(), Registered,
                             #{<<"$id">> => OldCanonical, <<"const">> => 1}),
    NewJson = #{<<"$id">> => NewCanonical, <<"const">> => 2},
    {ok, NewCanonical, NewStore} = valid_json_store:add(OldStore, Registered, NewJson),
    ?assertEqual(undefined, valid_json_store:fetch(OldCanonical, NewStore)),
    ?assertEqual(#document{registered = Registered,
                           canonical = NewCanonical,
                           json = NewJson},
                 valid_json_store:fetch(Registered, NewStore)).

%% Canonical alias не становится именем регистрации существующего document:
%% заменить запись можно только через её настоящее имя регистрации.
alias_is_not_upsert_test() ->
    Registered = <<"https://example.com/registered">>,
    Canonical = <<"https://example.com/canonical">>,
    {ok, Canonical, Store} =
        valid_json_store:add(valid_json_store:temporary(), Registered,
                             #{<<"$id">> => Canonical}),
    ?assertEqual(schema_error({name_taken, Canonical}),
                 valid_json_store:add(Store, Canonical, false)).

conflict_test() ->
    First = <<"https://example.com/first">>,
    Second = <<"https://example.com/second">>,
    Shared = <<"https://example.com/shared">>,
    FirstJson = #{<<"$id">> => Shared},
    {ok, Shared, Store} =
        valid_json_store:add(valid_json_store:temporary(), First, FirstJson),
    ?assertEqual(schema_error({name_taken, Shared}),
                 valid_json_store:add(Store, Second, #{<<"$id">> => Shared})),
    %% Провал не изменяет исходное immutable значение.
    ?assertEqual(#document{registered = First, canonical = Shared, json = FirstJson},
                 valid_json_store:fetch(Shared, Store)),
    ?assertEqual(undefined, valid_json_store:fetch(Second, Store)).

batch_test() ->
    Store0 = valid_json_store:new([{base_uri, ?BASE}]),
    Entries = [{<<"a">>, #{<<"$id">> => <<"canonical/a">>}},
               {<<"b">>, true}],
    A = <<"https://example.com/schemas/canonical/a">>,
    B = <<"https://example.com/schemas/b">>,
    {ok, [A, B], Store} = valid_json_store:add(Store0, Entries),
    ?assertMatch(#document{canonical = A}, valid_json_store:fetch(A, Store)),
    ?assertMatch(#document{canonical = B}, valid_json_store:fetch(B, Store)).

%% Все заменяемые записи снимаются до проверки нового набора, поэтому batch
%% допускает безопасную перестановку canonical имён.
batch_swap_test() ->
    RA = <<"https://example.com/a">>,
    RB = <<"https://example.com/b">>,
    CA = <<"https://example.com/canonical-a">>,
    CB = <<"https://example.com/canonical-b">>,
    {ok, [_CA, _CB], Store0} =
        valid_json_store:add(valid_json_store:temporary(),
                             [{RA, #{<<"$id">> => CA}},
                              {RB, #{<<"$id">> => CB}}]),
    {ok, [CB, CA], Store} =
        valid_json_store:add(Store0,
                             [{RA, #{<<"$id">> => CB}},
                              {RB, #{<<"$id">> => CA}}]),
    ?assertMatch(#document{registered = RA}, valid_json_store:fetch(CB, Store)),
    ?assertMatch(#document{registered = RB}, valid_json_store:fetch(CA, Store)).

batch_atomic_test() ->
    Existing = <<"https://example.com/existing">>,
    Free = <<"https://example.com/free">>,
    Conflict = <<"https://example.com/conflict">>,
    {ok, Conflict, Store} =
        valid_json_store:add(valid_json_store:temporary(), Existing,
                             #{<<"$id">> => Conflict}),
    Other = <<"https://example.com/other">>,
    ?assertEqual({error, [entry_error(Other, {name_taken, Conflict})]},
                 valid_json_store:add(Store, [{Free, true},
                                              {Other, #{<<"$id">> => Conflict}}])),
    ?assertEqual(undefined, valid_json_store:fetch(Free, Store)).

%% Записи разбираются независимо, поэтому негодные имена показываются все сразу,
%% и каждая ошибка названа тем написанием, с каким пришёл вызывающий.
batch_name_errors_test() ->
    Good = <<"https://example.com/good">>,
    ?assertEqual({error, [entry_error(<<"relative.json">>,
                                      relative_uri_without_base),
                          entry_error(<<"http://[::1">>, invalid_uri)]},
                 valid_json_store:add(valid_json_store:temporary(),
                                      [{<<"relative.json">>, true},
                                       {Good, true},
                                       {<<"http://[::1">>, true}])).

%% Конфликты имён тоже собираются все: отвергнутая запись не вставляется, но
%% обход продолжается.
batch_conflicts_test() ->
    Taken = <<"https://example.com/taken">>,
    Free = <<"https://example.com/free">>,
    First = <<"https://example.com/first">>,
    Second = <<"https://example.com/second">>,
    {ok, Taken, Store} =
        valid_json_store:add(valid_json_store:temporary(), Taken, true),
    ?assertEqual({error, [entry_error(First, {name_taken, Taken}),
                          entry_error(Second, {name_taken, Taken})]},
                 valid_json_store:add(Store, [{First, #{<<"$id">> => Taken}},
                                              {Free, true},
                                              {Second, #{<<"$id">> => Taken}}])).

remove_test() ->
    Registered = <<"https://example.com/registered">>,
    Canonical = <<"https://example.com/canonical">>,
    {ok, Canonical, Store0} =
        valid_json_store:add(valid_json_store:temporary(), Registered,
                             #{<<"$id">> => Canonical}),
    %% Удалить можно по любому из двух внешних имён, а снятый документ назван
    %% парой: написанием вызывающего и своим каноническим именем.
    {ok, Removed, Store1} = valid_json_store:remove(Store0, [Canonical]),
    ?assertEqual([{Canonical, Canonical}], Removed),
    ?assertEqual(undefined, valid_json_store:fetch(Registered, Store1)),
    ?assertEqual(undefined, valid_json_store:fetch(Canonical, Store1)),
    %% Неизвестное и встроенное имя операция не видит: пары они не дают и
    %% ошибкой не считаются.
    ?assertEqual({ok, [], Store1},
                 valid_json_store:remove(
                   Store1, [<<"https://example.com/missing">>, ?BUILTIN])).

%% Удаление по адресу загрузки называет в паре каноническое имя: по нему же
%% лежит артефакт.
remove_by_registered_name_test() ->
    Registered = <<"https://example.com/registered">>,
    Canonical = <<"https://example.com/canonical">>,
    {ok, Canonical, Store0} =
        valid_json_store:add(valid_json_store:temporary(), Registered,
                             #{<<"$id">> => Canonical}),
    {ok, Removed, Store1} = valid_json_store:remove(Store0, [Registered]),
    ?assertEqual([{Registered, Canonical}], Removed),
    ?assertEqual(undefined, valid_json_store:fetch(Canonical, Store1)).

remove_relative_test() ->
    Store0 = valid_json_store:new([{base_uri, ?BASE}]),
    {ok, Canonical, Store1} = valid_json_store:add(Store0, <<"a">>, true),
    {ok, Removed, Store2} = valid_json_store:remove(Store1, [<<"a">>]),
    ?assertEqual([{<<"a">>, Canonical}], Removed),
    ?assertEqual(undefined, valid_json_store:fetch(Canonical, Store2)).

%% Имена разбираются независимо, поэтому ошибки собираются все и называются
%% написанием записи — как при регистрации.
remove_name_errors_test() ->
    Store = valid_json_store:temporary(),
    ?assertEqual({error, [entry_error(<<"a">>, relative_uri_without_base),
                          entry_error(<<"b">>, relative_uri_without_base)]},
                 valid_json_store:remove(
                   Store, [<<"a">>, <<"https://example.com/schema">>, <<"b">>])).

builtin_test() ->
    Empty = valid_json_store:temporary(),
    Document = valid_json_store:fetch(?BUILTIN, Empty),
    ?assertMatch(#document{registered = ?BUILTIN,
                           canonical = ?BUILTIN,
                           json = #{<<"$id">> := ?BUILTIN}},
                 Document),
    %% format-assertion входит во встроенные документы, хотя корневая
    %% meta-schema на него по умолчанию не ссылается.
    ?assertMatch(#document{},
                 valid_json_store:fetch(
                   <<"https://json-schema.org/draft/2020-12/meta/format-assertion">>,
                   Empty)),
    %% Output schema лежит в priv рядом, но в immutable область не входит.
    ?assertEqual(undefined,
                 valid_json_store:fetch(
                   <<"https://json-schema.org/draft/2020-12/output/schema">>, Empty)),
    ?assertEqual(schema_error({name_taken, ?BUILTIN}),
                 valid_json_store:add(Empty, ?BUILTIN, true)),
    ?assertEqual(schema_error({name_taken, ?BUILTIN}),
                 valid_json_store:add(Empty, <<"https://example.com/schema">>,
                                      #{<<"$id">> => ?BUILTIN})).

schema_error(Reason) ->
    {error, #schema_error{reason = Reason, location = undefined}}.

%% Списочная регистрация называет каждую ошибку записью, к которой она
%% относится: её написанием либо `anonymous`, когда имя ещё не выведено.
entry_error(Name, Reason) ->
    {Name, #schema_error{reason = Reason, location = undefined}}.

%% Обе ступени подряд — так документ регистрирует управляющий, когда имени ему
%% не принесли.
named_add(Store, Schemas) ->
    case valid_json_store:name_entries(Store, Schemas) of
        {ok, Entries}      -> valid_json_store:add(Store, Entries);
        {error, _} = Error -> Error
    end.
