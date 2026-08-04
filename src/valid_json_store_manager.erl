%% Управляющий одного хранилища. Он держит реестр документов и опции, владеет
%% обеими таблицами хранилища и остаётся единственным, кто в них пишет. Здесь же
%% собрано знание о том, как имя хранилища превращается в имена таблиц и какая
%% раскладка у каждой из них.
%%
%% `lookup/2` — обычная функция, а не вызов: она исполняется в процессе
%% вызывающего, читает таблицу напрямую и управляющего не будит. Сообщением
%% идёт только запись, потому что путь холодный и сериализация на одном процессе
%% здесь как раз и нужна.
%%
%% Таблицы переживают смерть управляющего по `heir`, и реестр вместе с ними:
%% после перезапуска он поднимается из таблицы реестра, а не начинается пустым.
%% Артефактов без документа поэтому не остаётся. Обратное расхождение —
%% документы есть, артефактов нет — возникает при перезапуске хранителя
%% артефактов и закрывается пересборкой в `handle_continue`.
%%
%% Истина по реестру — `#state.store`: таблица реестра ему проекция, которая
%% нужна затем, чтобы пережить перезапуск. Оттого и порядок: значение меняется
%% первым и принимается только вместе с артефактами, а в таблицы уходит уже
%% принятое.
-module(valid_json_store_manager).

-behaviour(gen_server).

-include("valid_json_resources.hrl").

-export([start_link/2, manager_name/1, artifacts_table/1, registry_table/1,
         table_options/1, add/2, remove/2, lookup/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).
-export_type([add_error/0, store_option/0]).

-type add_error() :: {registration, [{uri(), #schema_error{}}]}
                   | {compilation, [{uri(), #schema_error{}}]}.
-type store_option() :: {base_uri, uri()}
                      | {default_dialect, dialect()}
                      | {assert_format, boolean()}.

-record(state, {
    table    :: atom(),
    registry :: atom(),
    store    :: store(),
    options  :: [valid_json_compile:compile_option()]
}).

-spec start_link(atom(), [store_option()]) -> {ok, pid()}.
start_link(Store, Options) ->
    gen_server:start_link({local, manager_name(Store)}, ?MODULE,
                          {Store, Options}, []).

%% Правило именования процесса живёт здесь, потому что под этим именем
%% регистрируется сам управляющий. Имена хранилищ приходят от приложения и
%% никогда из пользовательского ввода, поэтому пополнение таблицы атомов
%% безопасно.
-spec manager_name(atom()) -> atom().
manager_name(Store) ->
    list_to_atom(atom_to_list(Store) ++ "_manager").

%% Таблица артефактов называется именем самого хранилища: под этим именем в неё
%% ходят читатели, и менять его не за чем. Таблице реестра имя производится от
%% него же, поэтому оба хранителя получают разные имена сами собой.
-spec artifacts_table(atom()) -> atom().
artifacts_table(Store) ->
    Store.

-spec registry_table(atom()) -> atom().
registry_table(Store) ->
    list_to_atom(atom_to_list(Store) ++ "_registry").

%% Опции таблиц принадлежат тому, кто знает их содержимое, то есть этому модулю;
%% хранитель принимает их готовыми. Обе `protected`: писать может только
%% управляющий, а читать — любой процесс. Артефакты читаются на горячем пути
%% всегда, реестр — только на промахе коротким именем, но `read_concurrency`
%% дёшев и там.
-spec table_options(artifacts | registry) -> [term()].
table_options(artifacts) ->
    [set, protected, {read_concurrency, true}];
table_options(registry) ->
    [set, protected, {read_concurrency, true}].

%% Обе ветви ошибки списочные, а различает их тег, потому что имена в них значат
%% разное. У `registration` ключ — имя записи в написании вызывающего: до
%% артефактов дело не дошло, и канонического имени у отвергнутой записи может не
%% быть вовсе. У `compilation` ключ — каноническое имя, то самое, по которому
%% ходят в таблицу.
-spec add(atom(), [{uri(), json()}]) -> {ok, [uri()]} | {error, add_error()}.
add(Store, Entries) when is_list(Entries) ->
    gen_server:call(manager_name(Store), {add, Entries}).

%% У удаления фаза одна, поэтому и тега у ошибки нет: и неразрешимое имя, и
%% `referenced_by` названы написанием записи, и различать тут нечего.
-spec remove(atom(), [uri()]) -> ok | {error, [{uri(), #schema_error{}}]}.
remove(Store, Uris) when is_list(Uris) ->
    gen_server:call(manager_name(Store), {remove, Uris}).

%% Имя пробуется сперва как есть, и канонический вызов этим и заканчивается —
%% одним чтением. Разрешение от базы стоит второго чтения и достаётся только
%% промаху, то есть короткому имени. База читается из таблицы реестра: состояние
%% управляющего читателю не видно, а будить его на горячем пути незачем.
-spec lookup(atom(), uri()) -> {ok, compiled()} | {error, not_found}.
lookup(Store, Uri) ->
    case artifact(artifacts_table(Store), Uri) of
        {ok, _Compiled} = Found -> Found;
        {error, not_found}      -> lookup_resolved(Store, Uri)
    end.

-spec artifact(atom(), uri()) -> {ok, compiled()} | {error, not_found}.
artifact(Table, Name) ->
    case ets:lookup(Table, Name) of
        [{Name, Compiled}] -> {ok, Compiled};
        []                 -> {error, not_found}
    end.

%% Таблицы реестра может не быть вовсе: её хранитель перезапускается, и в этот
%% промежуток читатель обязан получить обычный промах, а не badarg.
-spec lookup_resolved(atom(), uri()) -> {ok, compiled()} | {error, not_found}.
lookup_resolved(Store, Uri) ->
    Registry = registry_table(Store),
    case ets:whereis(Registry) of
        undefined ->
            {error, not_found};
        _Tid ->
            case ets:lookup(Registry, base) of
                [{base, Base}] -> lookup_from(Store, Uri, Base);
                []             -> {error, not_found}
            end
    end.

-spec lookup_from(atom(), uri(), uri() | anonymous) ->
          {ok, compiled()} | {error, not_found}.
lookup_from(Store, Uri, Base) ->
    case valid_json_store:resolve_name(Uri, Base) of
        {ok, Uri} ->
            %% Разрешение ничего не изменило: повторное чтение дало бы тот же
            %% промах, с какого мы сюда и пришли.
            {error, not_found};
        {ok, Name} ->
            artifact(artifacts_table(Store), Name);
        {error, _Reason} ->
            {error, not_found}
    end.

%% Владение переходит в самом ets:give_away/3, поэтому ждать 'ETS-TRANSFER'
%% незачем: после ответа хранителя таблица уже наша. Отказ означает, что ею
%% владеет кто-то третий, а без владения писать всё равно нельзя.
%%
%% Реестр поднимается из своей таблицы, а база берётся из опции: опция приходит
%% через `start_link`, и супервизор перезапускает управляющего с той же самой,
%% поэтому сравнивать её с пережившей нечего. В таблицу база уходит односторонне,
%% для читателей.
init({Store, Options}) ->
    ok = check_options(Options),
    Artifacts = artifacts_table(Store),
    Registry = registry_table(Store),
    case claim([Registry, Artifacts]) of
        ok ->
            Registered = valid_json_store:from_documents(
                           documents(Registry), registry_options(Options)),
            true = ets:insert(Registry, {base, valid_json_store:base(Registered)}),
            {ok, #state{table = Artifacts, registry = Registry,
                        store = Registered, options = compile_options(Options)},
             {continue, repair}};
        {error, not_owner} ->
            {stop, {claim_failed, not_owner}}
    end.

%% Пересобирается то, у чего документ есть, а артефакта нет: так выглядит
%% хранилище после перезапуска хранителя артефактов. Обратного расхождения не
%% бывает — таблица артефактов переживает только те отказы, при которых
%% переживает и таблица реестра.
%%
%% Отказ компиляции здесь означает не ошибку вызывающего, а расхождение внутри
%% хранилища: эти документы уже компилировались с теми же опциями. Поэтому
%% падаем и отдаём решение супервизору.
handle_continue(repair, #state{table = Table, store = Store,
                               options = Options} = State) ->
    case missing(Table, valid_json_store:canonical_names(Store)) of
        [] ->
            {noreply, State};
        Names ->
            {ok, Artifacts} = compile_all(Names, Store, Options),
            commit(State, Artifacts, [], []),
            {noreply, State}
    end.

handle_call({add, Entries}, _From, State) ->
    {Reply, Next} = add_entries(Entries, State),
    {reply, Reply, Next};
handle_call({remove, Uris}, _From, State) ->
    {Reply, Next} = remove_entries(Uris, State),
    {reply, Reply, Next}.

handle_cast(_Message, State) ->
    {noreply, State}.

%% Уведомление о полученной таблице: работы оно не требует, потому что владение
%% перешло раньше, в ответе хранителя на claim.
handle_info({'ETS-TRANSFER', Table, _From, _Gift}, #state{table = Table} = State) ->
    {noreply, State};
handle_info({'ETS-TRANSFER', Registry, _From, _Gift},
            #state{registry = Registry} = State) ->
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.

-spec claim([atom()]) -> ok | {error, not_owner}.
claim([]) ->
    ok;
claim([Table | Rest]) ->
    case valid_json_ets_keeper:claim(Table) of
        ok                       -> claim(Rest);
        {error, not_owner} = Err -> Err
    end.

-spec documents(atom()) -> [#document{}].
documents(Registry) ->
    [Document || {_Key, Document}
                     <- ets:match_object(Registry, {{document, '_'}, '_'})].

-spec missing(atom(), [uri()]) -> [uri()].
missing(Table, Names) ->
    [Name || Name <- Names, ets:member(Table, Name) =:= false].

%% Реестр меняется первым, но принимается только вместе с артефактами: до
%% успешной компиляции всего пересобираемого набора состояние остаётся прежним.
-spec add_entries([{uri(), json()}], #state{}) ->
          {{ok, [uri()]} | {error, add_error()}, #state{}}.
add_entries(Entries, #state{table = Table, store = Store0,
                            options = Options} = State) ->
    Old = valid_json_store:canonical_names(Store0),
    case valid_json_store:add(Store0, Entries) of
        {error, Errors} ->
            {{error, {registration, Errors}}, State};
        {ok, Added, Store1} ->
            New = valid_json_store:canonical_names(Store1),
            Gone = ordsets:subtract(Old, New),
            Names = ordsets:from_list(Added),
            Changed = ordsets:union(Names, Gone),
            Rebuild = ordsets:union(Names, affected(Table, New, Changed)),
            case compile_all(Rebuild, Store1, Options) of
                {ok, Artifacts} ->
                    commit(State, Artifacts, rows(Added, Store1), Gone),
                    {{ok, Added}, State#state{store = Store1}};
                {error, Errors} ->
                    {{error, {compilation, Errors}}, State}
            end
    end.

%% Фазы компиляции у удаления нет: снятие, прошедшее проверку ссылок, не может
%% сломать ни одного оставшегося артефакта — тот, кто ссылался бы на снятое имя,
%% отвергнут раньше. Снятие из таблиц тоже не подводит: `ets:delete/2` доволен
%% и отсутствующим ключом, а упасть может только на потерянном владении, где
%% падать и следует.
-spec remove_entries([uri()], #state{}) ->
          {ok | {error, [{uri(), #schema_error{}}]}, #state{}}.
remove_entries(Uris, #state{table = Table, store = Store0} = State) ->
    case valid_json_store:remove(Store0, Uris) of
        {error, Errors} ->
            {{error, Errors}, State};
        {ok, Removed, Store1} ->
            Gone = ordsets:from_list([Name || {_Entry, Name} <- Removed]),
            Survivors = valid_json_store:canonical_names(Store1),
            case referenced(Table, Survivors, Removed, Gone) of
                [] ->
                    commit(State, [], [], Gone),
                    {ok, State#state{store = Store1}};
                Errors ->
                    {{error, Errors}, State}
            end
    end.

%% Ссылающихся ищут по `sources` выживших артефактов, и обратный индекс здесь
%% не нужен ровно как при добавлении. Одна ссылка отвергает вызов целиком:
%% удалить документ можно только вместе со всем конусом зависимых от него.
-spec referenced(atom(), [uri()], [{uri(), uri()}], [uri()]) ->
          [{uri(), #schema_error{}}].
referenced(Table, Survivors, Removed, Gone) ->
    Refs = lists:foldl(fun(Name, Acc) -> refers(Table, Name, Gone, Acc) end,
                       #{}, Survivors),
    [{Entry, #schema_error{reason = {referenced_by, Name, maps:get(Name, Refs)},
                           location = undefined}}
     || {Entry, Name} <- Removed, maps:is_key(Name, Refs)].

%% Имя реестра без артефакта здесь недостижимо: пересборка в `handle_continue`
%% закрывает это расхождение до первого вызова.
-spec refers(atom(), uri(), [uri()], #{uri() => [uri()]}) -> #{uri() => [uri()]}.
refers(Table, Name, Gone, Refs) ->
    case artifact(Table, Name) of
        {ok, #{sources := Sources}} ->
            Hit = ordsets:intersection(ordsets:from_list(Sources), Gone),
            lists:foldl(
              fun(Source, Acc) ->
                      maps:update_with(Source,
                                       fun(Names) -> ordsets:add_element(Name, Names) end,
                                       [Name], Acc)
              end, Refs, Hit);
        {error, not_found} ->
            Refs
    end.

%% Обратный индекс зависимостей не нужен: новый документ не может ни сломать, ни
%% починить чужой артефакт, потому что ссылающийся уже держал бы его в sources.
-spec affected(atom(), [uri()], [uri()]) -> [uri()].
affected(Table, Names, Changed) ->
    ordsets:from_list([Name || Name <- Names, stale(Table, Name, Changed)]).

-spec stale(atom(), uri(), [uri()]) -> boolean().
stale(Table, Name, Changed) ->
    case artifact(Table, Name) of
        {ok, #{sources := Sources}} ->
            ordsets:intersection(ordsets:from_list(Sources), Changed) =/= [];
        %% Имя реестра без артефакта пересобирается в любом случае.
        {error, not_found} ->
            true
    end.

-spec compile_all([uri()], store(), [valid_json_compile:compile_option()]) ->
          {ok, [{uri(), compiled()}]} | {error, [{uri(), #schema_error{}}]}.
compile_all(Names, Store, Options) ->
    Compile = fun(Name, {Artifacts, Errors}) ->
                      case valid_json_compile:compile_uri(Store, Name, Options) of
                          {ok, Compiled} ->
                              {[{Name, Compiled} | Artifacts], Errors};
                          {error, Error} ->
                              {Artifacts, [{Name, Error} | Errors]}
                      end
              end,
    case lists:foldl(Compile, {[], []}, Names) of
        {Artifacts, []} -> {ok, lists:reverse(Artifacts)};
        {_Artifacts, Errors} -> {error, lists:reverse(Errors)}
    end.

%% Документ лежит в таблице под своим каноническим именем и тегированным ключом:
%% служебная строка с базой не попадает в перебор документов по устройству
%% ключа, а не по договорённости. Адрес загрузки отдельным ключом не заводится —
%% он есть полем документа, и обратно реестр собирает оба ключа сам.
-spec rows([uri()], store()) -> [{{document, uri()}, #document{}}].
rows(Names, Store) ->
    [{{document, Name}, valid_json_store:fetch(Name, Store)} || Name <- Names].

%% Порядок обязателен: список ets:insert/2 атомарен и изолирован для читателей,
%% а удаление этой гарантией не закрыто. Так снятое имя отвечает ещё некоторое
%% время после reload, но ложного not_found для живого имени не возникает.
-spec commit(#state{}, [{uri(), compiled()}], [{{document, uri()}, #document{}}],
             [uri()]) -> ok.
commit(#state{table = Table, registry = Registry}, Artifacts, Documents, Gone) ->
    true = ets:insert(Table, Artifacts),
    true = ets:insert(Registry, Documents),
    lists:foreach(fun(Name) ->
                          true = ets:delete(Table, Name),
                          true = ets:delete(Registry, {document, Name})
                  end, Gone).

%% Незнакомая опция — ошибка конфигурации, а не пользовательского ввода, поэтому
%% она завершается badarg и обваливает старт хранилища громко.
-spec check_options([term()]) -> ok.
check_options([]) ->
    ok;
check_options([{Key, _Value} | Rest])
  when Key =:= base_uri; Key =:= default_dialect; Key =:= assert_format ->
    check_options(Rest);
check_options(Options) ->
    erlang:error(badarg, [Options]).

%% Негодное значение base_uri отвергнет сам реестр: правило допустимой базы
%% принадлежит ему.
-spec registry_options([store_option()]) -> [valid_json_store:registry_option()].
registry_options(Options) ->
    case option(base_uri, Options, undefined) of
        undefined -> [];
        Uri       -> [{base_uri, Uri}]
    end.

-spec compile_options([store_option()]) -> [valid_json_compile:compile_option()].
compile_options(Options) ->
    [{default_dialect, dialect(option(default_dialect, Options, ?DRAFT_2020_12))},
     {assert_format, assert_format(option(assert_format, Options, false))}].

dialect(Dialect) when is_binary(Dialect) -> Dialect;
dialect(Other) -> erlang:error(badarg, [{default_dialect, Other}]).

assert_format(Assert) when is_boolean(Assert) -> Assert;
assert_format(Other) -> erlang:error(badarg, [{assert_format, Other}]).

%% Одно правило на все три опции: значение вызова, затем app env библиотеки,
%% затем встроенное умолчание. Все три одинаково влияют на все артефакты
%% хранилища сразу, поэтому частных правил у них нет.
-spec option(atom(), [store_option()], term()) -> term().
option(Key, Options, Default) ->
    case lists:keyfind(Key, 1, Options) of
        {Key, Value} ->
            Value;
        false ->
            case application:get_env(valid_json, Key) of
                {ok, Value} -> Value;
                undefined   -> Default
            end
    end.
