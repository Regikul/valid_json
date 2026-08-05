%% Неизменяемая область встроенных JSON Schema meta-schemas. При старте
%% приложения все документы читаются один раз, две корневые метасхемы
%% компилируются доверенным bootstrap-путём и публикуются через persistent_term.
-module(valid_json_metaschema).

-include("valid_json_resources.hrl").

-export([publish/0, compiled/1, fetch/1, is_builtin/1]).

-define(KEY(Draft), {?MODULE, Draft}).

%% В bundle остаются и декодированные документы: обычный `$ref` на встроенную
%% метасхему должен получить исходный JSON, но повторно читать priv для этого не
%% нужно. Persistent term по-прежнему один на dialect.
-type bundle() :: #{compiled := compiled(),
                    documents := #{uri() => #document{}}}.

-spec publish() -> ok.
publish() ->
    %% Сначала строим обе записи целиком. Если bootstrap второй метасхемы
    %% провалится, первая ещё не опубликована и приложение не увидит половинчатую
    %% встроенную область.
    Modern = bundle(?DRAFT_2020_12, modern_documents()),
    Legacy = bundle(?DRAFT_2019_09, legacy_documents()),
    persistent_term:put(?KEY(?DRAFT_2020_12), Modern),
    persistent_term:put(?KEY(?DRAFT_2019_09), Legacy),
    ok.

%% Канонические корневые метасхемы — единственные persistent compiled artifacts.
-spec compiled(dialect()) -> compiled().
compiled(?DRAFT_2020_12 = Draft) ->
    maps:get(compiled, published_bundle(Draft));
compiled(?DRAFT_2019_09 = Draft) ->
    maps:get(compiled, published_bundle(Draft)).

-spec fetch(uri()) -> #document{} | undefined.
fetch(Uri) ->
    case builtin(Uri) of
        {Draft, _Relative} ->
            Bundle = published_bundle(Draft),
            maps:get(Uri, maps:get(documents, Bundle));
        undefined ->
            undefined
    end.

-spec is_builtin(uri()) -> boolean().
is_builtin(Uri) ->
    builtin(Uri) =/= undefined.

%% Прямое использование pure compile/store модулей не обязано предварительно
%% стартовать OTP application (так устроены и compiler fixtures). В обычном
%% release eager publish выполняет valid_json_app; fallback ниже сохраняет
%% прежнюю автономность API и сериализует конкурентные первые обращения.
-spec published_bundle(dialect()) -> bundle().
published_bundle(Draft) ->
    case persistent_term:get(?KEY(Draft), undefined) of
        undefined ->
            ok = ensure_published(),
            persistent_term:get(?KEY(Draft));
        Bundle ->
            Bundle
    end.

-spec ensure_published() -> ok.
ensure_published() ->
    Lock = {{?MODULE, publish}, self()},
    global:trans(
      Lock,
      fun() ->
              case {persistent_term:get(?KEY(?DRAFT_2020_12), undefined),
                    persistent_term:get(?KEY(?DRAFT_2019_09), undefined)} of
                  {undefined, _} -> publish();
                  {_, undefined} -> publish();
                  {_Modern, _Legacy} -> ok
              end
      end).

-spec bundle(dialect(), [{uri(), file:filename()}]) -> bundle().
bundle(Draft, Manifest) ->
    Documents = maps:from_list([load(Entry) || Entry <- Manifest]),
    Store = #store{documents = Documents},
    Root = maps:get(Draft, Documents),
    case valid_json_compile_closure:document(Store, Root, Draft) of
        {ok, Index, _BootstrapSources} ->
            %% Builtins никогда не входят в sources. Store выше существует
            %% только внутри bootstrap и потому не меняет это правило.
            %% Метасхема проверяет форму схемы, а не значения форматов, поэтому
            %% assertion ей не нужен ни при какой опции пользователя.
            case valid_json_compile_emit:emit(Index, [], false) of
                {ok, Compiled} ->
                    #{compiled => Compiled, documents => Documents};
                {error, Error} ->
                    erlang:error({builtin_metaschema_compile, Draft, Error})
            end;
        {error, Error} ->
            erlang:error({builtin_metaschema_closure, Draft, Error})
    end.

-spec load({uri(), file:filename()}) -> {uri(), #document{}}.
load({Uri, Relative}) ->
    Path = filename:join([priv_dir(), "json_schema", Relative]),
    case file:read_file(Path) of
        {ok, Encoded} ->
            Json = json:decode(Encoded),
            {Uri, #document{registered = Uri, canonical = Uri, json = Json}};
        {error, Reason} ->
            erlang:error({builtin_schema, Uri, Reason})
    end.

-spec priv_dir() -> file:filename_all().
priv_dir() ->
    case code:priv_dir(valid_json) of
        {error, bad_name} ->
            filename:join(filename:dirname(code:which(?MODULE)), "../priv");
        Directory ->
            Directory
    end.

-spec builtin(uri()) -> {dialect(), file:filename()} | undefined.
builtin(Uri) ->
    case lists:keyfind(Uri, 1, modern_documents() ++ legacy_documents()) of
        {Uri, Relative} -> {manifest_draft(Uri), Relative};
        false           -> undefined
    end.

-spec manifest_draft(uri()) -> dialect().
manifest_draft(<<"https://json-schema.org/draft/2020-12/", _/binary>>) ->
    ?DRAFT_2020_12;
manifest_draft(<<"https://json-schema.org/draft/2019-09/", _/binary>>) ->
    ?DRAFT_2019_09.

-spec modern_documents() -> [{uri(), file:filename()}].
modern_documents() ->
    [{?DRAFT_2020_12, "draft-2020-12/schema.json"},
     {<<"https://json-schema.org/draft/2020-12/meta/core">>,
      "draft-2020-12/meta/core.json"},
     {<<"https://json-schema.org/draft/2020-12/meta/applicator">>,
      "draft-2020-12/meta/applicator.json"},
     {<<"https://json-schema.org/draft/2020-12/meta/unevaluated">>,
      "draft-2020-12/meta/unevaluated.json"},
     {<<"https://json-schema.org/draft/2020-12/meta/validation">>,
      "draft-2020-12/meta/validation.json"},
     {<<"https://json-schema.org/draft/2020-12/meta/meta-data">>,
      "draft-2020-12/meta/meta-data.json"},
     {<<"https://json-schema.org/draft/2020-12/meta/format-annotation">>,
      "draft-2020-12/meta/format-annotation.json"},
     {<<"https://json-schema.org/draft/2020-12/meta/format-assertion">>,
      "draft-2020-12/meta/format-assertion.json"},
     {<<"https://json-schema.org/draft/2020-12/meta/content">>,
      "draft-2020-12/meta/content.json"}].

-spec legacy_documents() -> [{uri(), file:filename()}].
legacy_documents() ->
    [{?DRAFT_2019_09, "draft-2019-09/schema.json"},
     {<<"https://json-schema.org/draft/2019-09/meta/core">>,
      "draft-2019-09/meta/core.json"},
     {<<"https://json-schema.org/draft/2019-09/meta/applicator">>,
      "draft-2019-09/meta/applicator.json"},
     {<<"https://json-schema.org/draft/2019-09/meta/validation">>,
      "draft-2019-09/meta/validation.json"},
     {<<"https://json-schema.org/draft/2019-09/meta/meta-data">>,
      "draft-2019-09/meta/meta-data.json"},
     {<<"https://json-schema.org/draft/2019-09/meta/format">>,
      "draft-2019-09/meta/format.json"},
     {<<"https://json-schema.org/draft/2019-09/meta/content">>,
      "draft-2019-09/meta/content.json"}].
