%% Неизменяемая область встроенных JSON Schema meta-schemas. Исходные JSON
%% documents встроены в отдельный data-модуль, декодируются вместе, а четыре
%% корневые метасхемы компилируются доверенным bootstrap-путём. Размещённый
%% runtime публикует bundles в защищённой ETS; одноразовая проверка держит тот
%% же набор локальным значением.
%%
%% Этот же модуль владеет таблицей: в `init/1` он забирает её у хранителя,
%% публикует bundles и держит владение до конца жизни. Порядок «хранитель перед
%% владельцем» задан в valid_json_metaschema_sup, поэтому здесь нет ни ожидания
%% таблицы, ни блокировок: писать в неё может только владелец, и он один.
%%
%% Размещённый runtime читает таблицу напрямую, мимо процесса: содержимое
%% неизменяемо, и будить владельца ради чтения незачем. Локальный store до этой
%% ветки не доходит и потому не требует запущенного приложения.
-module(valid_json_metaschema).

-behaviour(gen_server).

-include("valid_json_resources.hrl").

-export([start_link/0, table/0, table_options/0]).
-export([with_local_bundles/1, compiled/1, compiled/2, fetch/1, fetch/2,
         is_builtin/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, ?MODULE).
-define(BUNDLES, bundles).

%% В bundle остаются и декодированные документы: обычный `$ref` на встроенную
%% метасхему должен получить исходный JSON, но повторно читать priv для этого не
%% нужно. В ETS лежит одна запись с bundles всех поддерживаемых dialects.
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
            %% Сначала строим все записи целиком. Если bootstrap одной
            %% метасхемы провалится, в таблицу не ляжет ни одна, и приложение
            %% не увидит половинчатую встроенную область.
            true = ets:insert(?TABLE, {?BUNDLES, build()}),
            ok
    end.

%% Одноразовый вызывающий держит те же immutable bundles обычным значением.
%% Такой store не зависит от application tree и не публикует ничего глобально.
-spec with_local_bundles(store()) -> store().
with_local_bundles(#store{} = Store) ->
    Store#store{metaschemas = build()}.

-spec build() -> #{dialect() => bundle()}.
build() ->
    Documents = documents(valid_json_metaschema_data:entries()),
    #{?DRAFT_2020_12 => bundle(?DRAFT_2020_12,
                               maps:get(?DRAFT_2020_12, Documents)),
      ?DRAFT_2019_09 => bundle(?DRAFT_2019_09,
                               maps:get(?DRAFT_2019_09, Documents)),
      ?DRAFT_07 => bundle(?DRAFT_07, maps:get(?DRAFT_07, Documents)),
      ?DRAFT_06 => bundle(?DRAFT_06, maps:get(?DRAFT_06, Documents))}.

%% Канонические корневые метасхемы — единственные immutable compiled artifacts.
-spec compiled(dialect()) -> compiled().
compiled(?DRAFT_2020_12 = Draft) ->
    maps:get(compiled, published_bundle(Draft));
compiled(?DRAFT_2019_09 = Draft) ->
    maps:get(compiled, published_bundle(Draft));
compiled(?DRAFT_07 = Draft) ->
    maps:get(compiled, published_bundle(Draft));
compiled(?DRAFT_06 = Draft) ->
    maps:get(compiled, published_bundle(Draft)).

-spec compiled(dialect(), store()) -> compiled().
compiled(Draft, #store{metaschemas = published}) ->
    compiled(Draft);
compiled(Draft, #store{metaschemas = Bundles}) when is_map(Bundles) ->
    maps:get(compiled, maps:get(Draft, Bundles)).

-spec fetch(uri()) -> #document{} | undefined.
fetch(Uri) ->
    fetch_bundles(Uri, published_bundles()).

-spec fetch(uri(), store()) -> #document{} | undefined.
fetch(Uri, #store{metaschemas = published}) ->
    fetch(Uri);
fetch(_Uri, #store{metaschemas = none}) ->
    undefined;
fetch(Uri, #store{metaschemas = Bundles}) when is_map(Bundles) ->
    fetch_bundles(Uri, Bundles).

-spec is_builtin(uri()) -> boolean().
is_builtin(Uri) ->
    valid_json_metaschema_data:entry(Uri) =/= undefined.

%% Таблицы нет — приложение не запущено, и починить это за вызывающего
%% библиотека не берётся: встроенную область поднимает дерево. Таблица есть, а
%% записи нет — значит сюда пришёл сам bootstrap, то есть ошибка внутри
%% `init/1`, и молчать о ней нельзя.
-spec published_bundle(dialect()) -> bundle().
published_bundle(Draft) ->
    maps:get(Draft, published_bundles()).

-spec published_bundles() -> #{dialect() => bundle()}.
published_bundles() ->
    try ets:lookup(?TABLE, ?BUNDLES) of
        [{?BUNDLES, Bundles}] ->
            Bundles;
        [] ->
            erlang:error(metaschema_unpublished)
    catch
        error:badarg ->
            erlang:error({application_not_started, valid_json})
    end.

-spec fetch_bundles(uri(), #{dialect() => bundle()}) -> #document{} | undefined.
fetch_bundles(Uri, Bundles) ->
    Find = fun(_Draft, Bundle, undefined) ->
                   maps:get(Uri, maps:get(documents, Bundle), undefined);
              (_Draft, _Bundle, Document) ->
                   Document
           end,
    maps:fold(Find, undefined, Bundles).

-spec bundle(dialect(), #{uri() => #document{}}) -> bundle().
bundle(Draft, Documents) ->
    Store = #store{documents = Documents, metaschemas = none},
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

-spec documents([{uri(), binary()}]) ->
          #{dialect() => #{uri() => #document{}}}.
documents(Entries) ->
    lists:foldl(fun add_document/2, #{}, Entries).

-spec add_document({uri(), binary()},
                   #{dialect() => #{uri() => #document{}}}) ->
          #{dialect() => #{uri() => #document{}}}.
add_document({Uri, Encoded}, Groups) ->
    Json = json:decode(Encoded),
    Uri = document_uri(maps:get(<<"$id">>, Json)),
    Dialect = document_uri(maps:get(<<"$schema">>, Json)),
    Document = #document{registered = Uri, canonical = Uri, json = Json},
    Documents = maps:get(Dialect, Groups, #{}),
    maps:put(Dialect, maps:put(Uri, Document, Documents), Groups).

%% Registry names identify documents, so an explicitly written empty fragment
%% in Draft 6/7 is not part of the key.
-spec document_uri(uri()) -> uri().
document_uri(Uri) ->
    case byte_size(Uri) of
        0 -> Uri;
        Size ->
            case binary:at(Uri, Size - 1) of
                $# -> binary:part(Uri, 0, Size - 1);
                _  -> Uri
            end
    end.
