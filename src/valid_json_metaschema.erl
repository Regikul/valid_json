%% Неизменяемая область встроенных JSON Schema meta-schemas. Все документы
%% читаются один раз, четыре корневые метасхемы компилируются доверенным
%% bootstrap-путём и ложатся в защищённую ETS одной записью.
%%
%% Этот же модуль владеет таблицей: в `init/1` он забирает её у хранителя,
%% публикует bundle и держит владение до конца жизни. Порядок «хранитель перед
%% владельцем» задан в valid_json_metaschema_sup, поэтому здесь нет ни ожидания
%% таблицы, ни блокировок: писать в неё может только владелец, и он один.
%%
%% Читают таблицу напрямую, мимо процесса: содержимое неизменяемо, и будить
%% владельца ради чтения незачем. Отсутствие таблицы означает незапущенное
%% приложение, и это ошибка вызывающего, а не случай, который библиотека чинит
%% за него.
-module(valid_json_metaschema).

-behaviour(gen_server).

-include("valid_json_resources.hrl").

-export([start_link/0, table/0, table_options/0]).
-export([compiled/1, fetch/1, is_builtin/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, ?MODULE).
-define(BUNDLES, bundles).

%% В bundle остаются и декодированные документы: обычный `$ref` на встроенную
%% метасхему должен получить исходный JSON, но повторно читать priv для этого не
%% нужно. В ETS лежит одна запись с обоими dialect bundles.
-type bundle() :: #{compiled := compiled(),
                    documents := #{uri() => #document{}}}.

%% Имя таблицы и её раскладку называет тот, кто знает, что в ней лежит. Спеку
%% хранителя по ним составляет супервизор ветки.
-spec table() -> atom().
table() ->
    ?TABLE.

-spec table_options() -> [term()].
table_options() ->
    [set, protected, {read_concurrency, true}].

%% Имени у процесса нет намеренно: держит его супервизор, а обращаться к нему
%% некому — читатели ходят в таблицу.
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    case valid_json_ets_keeper:claim(?TABLE) of
        ok ->
            ok = publish(),
            {ok, ?TABLE};
        {error, not_owner} ->
            {stop, {claim_failed, not_owner}}
    end.

%% Сообщений владельцу никто не шлёт: имени у него нет, а таблицу читают
%% напрямую. Клаузы объявлены потому, что их требует behaviour.
handle_call(_Request, _From, Table) ->
    {reply, {error, unsupported}, Table}.

handle_cast(_Message, Table) ->
    {noreply, Table}.

%% Уведомление о полученной таблице: владение перешло раньше, в ответе
%% хранителя на `claim`.
handle_info({'ETS-TRANSFER', Table, _From, _Gift}, Table) ->
    {noreply, Table};
handle_info(_Message, Table) ->
    {noreply, Table}.

%% Запись на месте означает перезапуск владельца: таблица пережила его у
%% хранителя по `heir` вместе с содержимым, и пересобирать неизменяемое незачем.
-spec publish() -> ok.
publish() ->
    case ets:lookup(?TABLE, ?BUNDLES) of
        [{?BUNDLES, _Bundles}] ->
            ok;
        [] ->
            %% Сначала строим все четыре записи целиком. Если bootstrap любой
            %% метасхемы провалится, в таблицу не ляжет ни одна, и приложение
            %% не увидит половинчатую встроенную область.
            Modern = bundle(?DRAFT_2020_12, modern_documents()),
            Legacy = bundle(?DRAFT_2019_09, legacy_documents()),
            Classic06 = bundle(?DRAFT_06, classic_documents(?DRAFT_06)),
            Classic07 = bundle(?DRAFT_07, classic_documents(?DRAFT_07)),
            true = ets:insert(?TABLE, {?BUNDLES,
                                       #{?DRAFT_2020_12 => Modern,
                                         ?DRAFT_2019_09 => Legacy,
                                         ?DRAFT_06 => Classic06,
                                         ?DRAFT_07 => Classic07}}),
            ok
    end.

%% Канонические корневые метасхемы — единственные immutable compiled artifacts.
-spec compiled(dialect()) -> compiled().
compiled(?DRAFT_2020_12 = Draft) ->
    maps:get(compiled, published_bundle(Draft));
compiled(?DRAFT_2019_09 = Draft) ->
    maps:get(compiled, published_bundle(Draft));
compiled(?DRAFT_06 = Draft) ->
    maps:get(compiled, published_bundle(Draft));
compiled(?DRAFT_07 = Draft) ->
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

%% Таблицы нет — приложение не запущено, и починить это за вызывающего
%% библиотека не берётся: встроенную область поднимает дерево. Таблица есть, а
%% записи нет — значит сюда пришёл сам bootstrap, то есть ошибка внутри
%% `init/1`, и молчать о ней нельзя.
-spec published_bundle(dialect()) -> bundle().
published_bundle(Draft) ->
    try ets:lookup(?TABLE, ?BUNDLES) of
        [{?BUNDLES, Bundles}] ->
            maps:get(Draft, Bundles);
        [] ->
            erlang:error({metaschema_unpublished, Draft})
    catch
        error:badarg ->
            erlang:error({application_not_started, valid_json})
    end.

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
    case lists:keyfind(Uri, 1,
                       modern_documents() ++ legacy_documents()
                       ++ classic_documents()) of
        {Uri, Relative} -> {manifest_draft(Uri), Relative};
        false           -> undefined
    end.

-spec manifest_draft(uri()) -> dialect().
manifest_draft(<<"https://json-schema.org/draft/2020-12/", _/binary>>) ->
    ?DRAFT_2020_12;
manifest_draft(<<"https://json-schema.org/draft/2019-09/", _/binary>>) ->
    ?DRAFT_2019_09;
manifest_draft(<<"http://json-schema.org/draft-06/", _/binary>>) ->
    ?DRAFT_06;
manifest_draft(<<"http://json-schema.org/draft-07/", _/binary>>) ->
    ?DRAFT_07.

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

-spec classic_documents() -> [{uri(), file:filename()}].
classic_documents() ->
    classic_documents(?DRAFT_06) ++ classic_documents(?DRAFT_07).

-spec classic_documents(dialect()) -> [{uri(), file:filename()}].
classic_documents(?DRAFT_06) ->
    [{?DRAFT_06, "draft-06/schema.json"}];
classic_documents(?DRAFT_07) ->
    [{?DRAFT_07, "draft-07/schema.json"}].
