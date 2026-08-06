%% Слой URI. Ссылка распадается на имя документа и цель внутри resource;
%% проверяются обе половины, порядок шагов между ними и промахи поиска.
-module(valid_json_uri_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

-define(BASE, <<"http://localhost:1234/nested/root.json">>).

%% Имя документа берётся из ссылки без fragment и разрешается относительно базы.
document_test_() ->
    [?_assertEqual({ok, <<"http://localhost:1234/nested/other.json">>, root},
                   valid_json_uri:resolve(<<"other.json">>, ?BASE)),
     ?_assertEqual({ok, <<"http://localhost:1234/other.json">>, root},
                   valid_json_uri:resolve(<<"../other.json">>, ?BASE)),
     ?_assertEqual({ok, <<"http://localhost:1234/absolute">>, root},
                   valid_json_uri:resolve(<<"/absolute">>, ?BASE)),
     %% Абсолютную ссылку база не меняет.
     ?_assertEqual({ok, <<"https://example.com/x">>, root},
                   valid_json_uri:resolve(<<"https://example.com/x">>, ?BASE)),
     %% Same-document reference: пустая ссылка и "#" дают сам base URI.
     ?_assertEqual({ok, ?BASE, root}, valid_json_uri:resolve(<<>>, ?BASE)),
     ?_assertEqual({ok, ?BASE, root}, valid_json_uri:resolve(<<"#">>, ?BASE)),
     %% Fragment в имя документа не входит.
     ?_assertEqual({ok, <<"http://localhost:1234/nested/other.json">>,
                    {anchor, <<"foo">>}},
                   valid_json_uri:resolve(<<"other.json#foo">>, ?BASE))].

%% Каноническая форма имени — результат scheme-based normalization. Она же
%% служит ключом реестра, поэтому применяется и к разрешённой ссылке.
normalize_test_() ->
    [?_assertEqual({ok, <<"http://example.com/a/c">>},
                   valid_json_uri:normalize(<<"HTTP://Example.COM:80/a/./b/../c">>)),
     ?_assertEqual({ok, <<"http://example.com/a/c">>, root},
                   valid_json_uri:resolve(<<"HTTP://Example.COM:80/a/./b/../c">>,
                                          anonymous)),
     %% Percent-encoding unreserved-символов раскрывается, регистр пути — нет.
     ?_assertEqual({ok, <<"http://example.com/A~b">>},
                   valid_json_uri:normalize(<<"http://example.com/%41%7Eb">>)),
     %% Пустой fragment отрезается до нормализации: эквивалентность имени с ним
     %% и без него в RFC-нормализацию не входит.
     ?_assertEqual({ok, <<"http://example.com/a">>, root},
                   valid_json_uri:resolve(<<"http://example.com/a#">>, anonymous)),
     ?_assertEqual({error, invalid_uri}, valid_json_uri:normalize(<<"http://[::1">>))].

%% У anonymous root базы нет. Fragment-only ссылка остаётся внутри него,
%% абсолютная уходит наружу, относительная разрешаться не с чем.
anonymous_test_() ->
    [?_assertEqual({ok, anonymous, root}, valid_json_uri:resolve(<<"#">>, anonymous)),
     ?_assertEqual({ok, anonymous, {anchor, <<"foo">>}},
                   valid_json_uri:resolve(<<"#foo">>, anonymous)),
     ?_assertEqual({ok, anonymous, {pointer, [<<"a">>, <<"$defs">>]}},
                   valid_json_uri:resolve(<<"#/$defs/a">>, anonymous)),
     ?_assertEqual({ok, <<"http://example.com/x">>, {pointer, [<<"a">>]}},
                   valid_json_uri:resolve(<<"http://example.com/x#/a">>, anonymous)),
     ?_assertEqual({error, relative_uri_without_base},
                   valid_json_uri:resolve(<<"other.json">>, anonymous)),
     ?_assertEqual({error, relative_uri_without_base},
                   valid_json_uri:resolve(<<"/absolute">>, anonymous)),
     %% Нормализация относительной ссылки вернула бы её неизменной и скрыла бы
     %% отсутствие базы, поэтому она стоит после разрешения, а не до.
     ?_assertEqual({error, relative_uri_without_base},
                   valid_json_uri:resolve(<<"./a/../b">>, anonymous)),
     %% Пустая база — тоже отсутствие базы, а не пустое имя.
     ?_assertEqual({error, relative_uri_without_base},
                   valid_json_uri:resolve(<<"other.json">>, <<>>))].

%% Fragment читается как JSON Pointer только с ведущей косой чертой; всё
%% остальное — plain-name anchor, синтаксис которого здесь не проверяется.
target_test_() ->
    [?_assertEqual({ok, ?BASE, root}, valid_json_uri:resolve(<<"#">>, ?BASE)),
     ?_assertEqual({ok, ?BASE, {pointer, [<<"a">>, <<"$defs">>]}},
                   valid_json_uri:resolve(<<"#/$defs/a">>, ?BASE)),
     ?_assertEqual({ok, ?BASE, {anchor, <<"foo">>}},
                   valid_json_uri:resolve(<<"#foo">>, ?BASE)),
     %% Двоеточие в имени допускает Draft 2019-09; отказ, если он нужен, даёт
     %% метасхема в точке объявления `$anchor`.
     ?_assertEqual({ok, ?BASE, {anchor, <<"foo:bar">>}},
                   valid_json_uri:resolve(<<"#foo:bar">>, ?BASE)),
     %% Корень resource — и пустой указатель тоже.
     ?_assertEqual({ok, ?BASE, {pointer, [<<>>]}},
                   valid_json_uri:resolve(<<"#/">>, ?BASE))].

%% Percent-encoding снимается целиком и ровно один раз, и лишь затем указатель
%% разбирается на сегменты. Поэтому "%2F" становится разделителем, а не
%% экранированной косой чертой внутри сегмента.
pointer_test_() ->
    [?_assertEqual({ok, ?BASE, {pointer, [<<"b">>, <<"a">>, <<"$defs">>]}},
                   valid_json_uri:resolve(<<"#/$defs/a%2Fb">>, ?BASE)),
     %% Литеральную косую черту в имени свойства даёт "~1", даже записанный
     %% через percent-encoding.
     ?_assertEqual({ok, ?BASE, {pointer, [<<"a/b">>]}},
                   valid_json_uri:resolve(<<"#/a~1b">>, ?BASE)),
     ?_assertEqual({ok, ?BASE, {pointer, [<<"/">>]}},
                   valid_json_uri:resolve(<<"#/%7E1">>, ?BASE)),
     %% "~1" разбирается раньше "~0", иначе "~01" превратилось бы в косую черту.
     ?_assertEqual({ok, ?BASE, {pointer, [<<"a~1b">>]}},
                   valid_json_uri:resolve(<<"#/a~01b">>, ?BASE)),
     %% Однократность декодирования: за два прохода "%2525" дало бы "%".
     ?_assertEqual({ok, ?BASE, {anchor, <<"%25">>}},
                   valid_json_uri:resolve(<<"#%2525">>, ?BASE)),
     %% Пустые сегменты сохраняются: в ref.json есть цель "#/$defs//$defs/".
     ?_assertEqual({ok, ?BASE, {pointer, [<<>>, <<"$defs">>, <<>>, <<"$defs">>]}},
                   valid_json_uri:resolve(<<"#/$defs//$defs/">>, ?BASE)),
     %% Не-ASCII имя приходит percent-encoded и восстанавливается в UTF-8.
     ?_assertEqual({ok, ?BASE, {pointer, [<<"ф"/utf8>>]}},
                   valid_json_uri:resolve(<<"#/%D1%84">>, ?BASE))].

%% URN и прочие схемы без authority обрабатываются общими правилами RFC 3986,
%% без знания их внутренней структуры.
urn_test_() ->
    Urn = <<"urn:uuid:deadbeef-1234-0000-0000-4321feebdaed">>,
    [?_assertEqual({ok, Urn, root}, valid_json_uri:resolve(Urn, anonymous)),
     ?_assertEqual({ok, Urn, {pointer, [<<"bar">>, <<"$defs">>]}},
                   valid_json_uri:resolve(<<"#/$defs/bar">>, Urn)),
     %% Относительная ссылка внутри URN разрешается формально корректно, но
     %% бессмысленно; специального запрета нет — такое имя просто не найдётся в
     %% реестре.
     ?_assertEqual({ok, <<"urn:sibling.json">>, root},
                   valid_json_uri:resolve(<<"sibling.json">>, <<"urn:example:root">>))].

%% Ошибки слоя. Компилятор укладывает их в каталог причин сам, добавляя локацию.
error_test_() ->
    [?_assertEqual({error, invalid_uri},
                   valid_json_uri:resolve(<<"http://[::1">>, ?BASE)),
     ?_assertEqual({error, invalid_uri}, valid_json_uri:resolve(<<"#/a b">>, ?BASE)),
     %% Битая escape-последовательность и октеты, не складывающиеся в UTF-8,
     %% означают для fragment одно и то же.
     ?_assertEqual({error, invalid_percent_encoding},
                   valid_json_uri:resolve(<<"#%zz">>, ?BASE)),
     ?_assertEqual({error, invalid_percent_encoding},
                   valid_json_uri:resolve(<<"#%FF">>, ?BASE)),
     %% Имя документа разбирается раньше цели, поэтому о нём и сообщается.
     ?_assertEqual({error, relative_uri_without_base},
                   valid_json_uri:resolve(<<"other.json#%zz">>, anonymous))].

%% Цель ищется среди построенных nodes и объявленных anchors. Промах остаётся
%% голым `error`: причину каталога выбирает компилятор.
lookup_test_() ->
    Resource = resource(#{<<"foo">> => <<"/$defs/a">>, <<"dangling">> => <<"/$defs/x">>},
                        [<<>>, <<"/$defs/a">>]),
    [?_assertEqual({ok, <<>>}, valid_json_uri:lookup(root, Resource)),
     ?_assertEqual({ok, <<"/$defs/a">>},
                   valid_json_uri:lookup({pointer, [<<"a">>, <<"$defs">>]}, Resource)),
     %% Сегменты печатаются с pointer escaping, поэтому ключ node совпадает.
     ?_assertEqual(error, valid_json_uri:lookup({pointer, [<<"a/b">>]}, Resource)),
     ?_assertEqual(error, valid_json_uri:lookup({pointer, [<<"nope">>]}, Resource)),
     ?_assertEqual({ok, <<"/$defs/a">>},
                   valid_json_uri:lookup({anchor, <<"foo">>}, Resource)),
     ?_assertEqual(error, valid_json_uri:lookup({anchor, <<"bar">>}, Resource)),
     %% Индекс anchors не освобождает от проверки: цель обязана быть node.
     ?_assertEqual(error, valid_json_uri:lookup({anchor, <<"dangling">>}, Resource))].

%% Разбор ссылки и поиск цели стыкуются через готовый target.
resolve_and_lookup_test() ->
    Resource = resource(#{}, [<<>>, <<"/$defs/a~1b">>]),
    {ok, ?BASE, Target} = valid_json_uri:resolve(<<"#/$defs/a~1b">>, ?BASE),
    ?assertEqual({ok, <<"/$defs/a~1b">>}, valid_json_uri:lookup(Target, Resource)).

resource(Anchors, Pointers) ->
    #resource{id = ?BASE,
              dialect = <<"https://json-schema.org/draft/2020-12/schema">>,
              anchors = Anchors,
              dynamic_anchors = #{},
              nodes = maps:from_list([{Pointer, true} || Pointer <- Pointers])}.
