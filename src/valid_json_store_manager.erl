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
%%
%% Стартовый набор документов приходит от загрузчика, если он задан опцией.
%% Читается он в `handle_continue`, то есть до первого обслуженного сообщения, и
%% ровно один раз: на холодном старте и после потери реестра. Отслеживают это две
%% служебные строки, и каждая лежит в той таблице, чью полноту описывает:
%% `loaded` в реестре говорит, что загрузчик прочитан, `ready` в артефактах — что
%% набор артефактов полон. Снимать их не нужно, каждая исчезает вместе со своей
%% таблицей.
-module(valid_json_store_manager).

-behaviour(gen_server).

-include("valid_json_resources.hrl").

-export([start_link/2, manager_name/1, artifacts_table/1, registry_table/1,
         table_options/1, add/2, add_at/2, remove/2, lookup/2, wait/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).
-export_type([add_error/0, store_option/0]).

-type add_error() :: {registration, [{rid(), #schema_error{}}]}
                   | {compilation, [{uri(), #schema_error{}}]}.
-type store_option() :: {base_uri, uri()}
                      | {default_dialect, dialect()}
                      | {assert_format, boolean()}
                      | {loader, valid_json_loader:loader()}.

%% Промежуток между попытками в `wait`: имя управляющего в перезапуске бывает не
%% зарегистрировано, и ждать его можно только повторной попыткой.
-define(RETRY, 50).

-record(state, {
    table    :: atom(),
    registry :: atom(),
    store    :: store(),
    options  :: [valid_json_compile:compile_option()],
    loader   :: valid_json_loader:loader() | undefined
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
%% быть вовсе; у схемы, назвавшей себя сама, написания нет вовсе, и ключом
%% служит `anonymous`. У `compilation` ключ — каноническое имя, то самое, по
%% которому ходят в таблицу.
%%
%% Дверей две, потому что имя документа приходит из двух разных мест, и
%% различать их по устройству аргумента значило бы вернуть ту самую
%% двусмысленность, ради которой ступени и разведены. `add/2` берёт схемы и
%% выводит имена из `$id`; `add_at/2` берёт готовые пары и идёт прямо в реестр.
%% Загрузчик ходит второй: путь к файлу у него есть.
-spec add(atom(), [json()]) -> {ok, [uri()]} | {error, add_error()}.
add(Store, Schemas) when is_list(Schemas) ->
    gen_server:call(manager_name(Store), {add_schemas, Schemas}).

-spec add_at(atom(), [{uri(), json()}]) -> {ok, [uri()]} | {error, add_error()}.
add_at(Store, Entries) when is_list(Entries) ->
    gen_server:call(manager_name(Store), {add_entries, Entries}).

%% У удаления фаза одна, поэтому и тега у ошибки нет: и неразрешимое имя, и
%% `referenced_by` названы написанием записи, и различать тут нечего.
-spec remove(atom(), [uri()]) -> ok | {error, [{uri(), #schema_error{}}]}.
remove(Store, Uris) when is_list(Uris) ->
    gen_server:call(manager_name(Store), {remove, Uris}).

%% Имя пробуется сперва как есть, и канонический вызов этим и заканчивается —
%% одним чтением. Разрешение от `base_uri` стоит второго чтения и достаётся
%% только промаху, то есть короткому имени. `base_uri` читается из таблицы
%% реестра: состояние управляющего читателю не видно, а будить его на горячем
%% пути незачем.
-spec lookup(atom(), uri()) ->
          {ok, compiled()} | {error, not_found} | {error, unavailable}.
lookup(Store, Uri) ->
    case read(artifacts_table(Store), Uri) of
        {ok, _Compiled} = Found  -> Found;
        {error, not_found}       -> lookup_resolved(Store, Uri);
        {error, unavailable} = E -> E
    end.

%% Таблицы может не быть вовсе: её хранитель перезапускается, и попасть в это
%% окно читатель может в любой момент. Падать здесь нельзя — чтение исполняется
%% в его собственном процессе.
-spec read(atom(), term()) -> {ok, term()} | {error, not_found | unavailable}.
read(Table, Key) ->
    try ets:lookup(Table, Key) of
        [{Key, Value}] -> {ok, Value};
        []             -> {error, not_found}
    catch
        error:badarg -> {error, unavailable}
    end.

%% Внутреннее чтение управляющего: он владеет таблицей, поэтому её отсутствие
%% для него не окно, а потеря владения, и падать на ней следует.
-spec artifact(atom(), uri()) -> {ok, compiled()} | {error, not_found}.
artifact(Table, Name) ->
    case ets:lookup(Table, Name) of
        [{Name, Compiled}] -> {ok, Compiled};
        []                 -> {error, not_found}
    end.

%% Промах разбирается до всякого разрешения имени: пока отметки готовности нет,
%% набор артефактов неполон, и «имени нет» сказать не о чем. Отметка живёт в
%% таблице артефактов, потому что описывает полноту именно её содержимого:
%% смерть управляющего таблицу не трогает и окна не открывает, а перезапуск
%% любого из хранителей уносит отметку вместе с таблицей.
-spec lookup_resolved(atom(), uri()) ->
          {ok, compiled()} | {error, not_found} | {error, unavailable}.
lookup_resolved(Store, Uri) ->
    case read(artifacts_table(Store), ready) of
        {ok, true} -> lookup_short(Store, Uri);
        _Other     -> {error, unavailable}
    end.

%% `base_uri` читается из таблицы реестра, потому что состояние управляющего
%% читателю не видно, а будить его на горячем пути незачем. Его отсутствие
%% оставляет промах промахом: хранилище о своей готовности уже сказало, а
%% разрешить короткое имя не от чего.
-spec lookup_short(atom(), uri()) ->
          {ok, compiled()} | {error, not_found} | {error, unavailable}.
lookup_short(Store, Uri) ->
    case read(registry_table(Store), base) of
        {ok, Base} -> lookup_from(Store, Uri, Base);
        _Other     -> {error, not_found}
    end.

-spec lookup_from(atom(), uri(), uri()) ->
          {ok, compiled()} | {error, not_found} | {error, unavailable}.
lookup_from(Store, Uri, Base) ->
    case valid_json_store:resolve_name(Uri, Base) of
        {ok, Uri} ->
            %% Разрешение ничего не изменило: повторное чтение дало бы тот же
            %% промах, с какого мы сюда и пришли.
            {error, not_found};
        {ok, Name} ->
            read_artifact(artifacts_table(Store), Name);
        {error, _Reason} ->
            {error, not_found}
    end.

-spec read_artifact(atom(), uri()) ->
          {ok, compiled()} | {error, not_found} | {error, unavailable}.
read_artifact(Table, Name) ->
    case read(Table, Name) of
        {ok, _Compiled} = Found  -> Found;
        {error, not_found}       -> {error, not_found};
        {error, unavailable} = E -> E
    end.

%% Монитор ставится до подтверждения готовности, иначе между «готово» и
%% `erlang:monitor` вызывающего помещалась бы смерть управляющего, о которой он
%% уже не узнал бы. Обратный порядок безвреден: `DOWN` о прежнем управляющем
%% заставит вызывающего переспросить, только и всего.
-spec wait(atom(), timeout()) -> {ok, reference()} | {error, timeout}.
wait(Store, Timeout) ->
    wait_ready(manager_name(Store), deadline(Timeout)).

%% Монитор ставится на pid, а не на имя: так `DOWN` называет процесс обычным
%% образом, а подтверждает готовность ровно тот, за кем вызывающий и следит —
%% вызов уходит на тот же pid.
-spec wait_ready(atom(), integer() | infinity) ->
          {ok, reference()} | {error, timeout}.
wait_ready(Name, Deadline) ->
    case whereis(Name) of
        undefined -> retry(Name, Deadline);
        Pid       -> confirm(Pid, Name, Deadline)
    end.

-spec confirm(pid(), atom(), integer() | infinity) ->
          {ok, reference()} | {error, timeout}.
confirm(Pid, Name, Deadline) ->
    Ref = erlang:monitor(process, Pid),
    case left(Deadline) of
        0 ->
            give_up(Ref);
        Left ->
            try gen_server:call(Pid, ready, Left) of
                ok -> {ok, Ref}
            catch
                %% Свой таймаут вызывающего исчерпан; всё остальное означает,
                %% что управляющего сейчас нет, и его стоит подождать.
                exit:{timeout, _Call} ->
                    give_up(Ref);
                exit:{_Reason, _Call} ->
                    true = demonitor(Ref, [flush]),
                    retry(Name, Deadline)
            end
    end.

%% Имя в промежутке перезапуска бывает не зарегистрировано, и ждать его можно
%% только повторной попыткой: вызывающий написал бы тот же цикл.
-spec retry(atom(), integer() | infinity) ->
          {ok, reference()} | {error, timeout}.
retry(Name, Deadline) ->
    case left(Deadline) of
        0        -> {error, timeout};
        infinity -> timer:sleep(?RETRY), wait_ready(Name, Deadline);
        Left     -> timer:sleep(min(?RETRY, Left)), wait_ready(Name, Deadline)
    end.

-spec give_up(reference()) -> {error, timeout}.
give_up(Ref) ->
    true = demonitor(Ref, [flush]),
    {error, timeout}.

-spec deadline(timeout()) -> integer() | infinity.
deadline(infinity) ->
    infinity;
deadline(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    erlang:monotonic_time(millisecond) + Timeout.

-spec left(integer() | infinity) -> timeout().
left(infinity) ->
    infinity;
left(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

%% Владение переходит в самом ets:give_away/3, поэтому ждать 'ETS-TRANSFER'
%% незачем: после ответа хранителя таблица уже наша. Отказ означает, что ею
%% владеет кто-то третий, а без владения писать всё равно нельзя.
%%
%% Реестр поднимается из своей таблицы, а `base_uri` берётся из опции, но не из
%% пережившей таблицы: опция приходит через `start_link`, и супервизор
%% перезапускает управляющего с той же самой, поэтому сравнивать её с пережившей
%% нечего. В таблицу `base_uri` уходит односторонне, для читателей.
init({Store, Options}) ->
    ok = check_options(Options),
    Loader = option(loader, Options, undefined),
    Artifacts = artifacts_table(Store),
    Registry = registry_table(Store),
    case claim([Registry, Artifacts]) of
        ok ->
            Registered = valid_json_store:from_documents(
                           documents(Registry), registry_options(Options)),
            true = ets:insert(Registry, {base, valid_json_store:base(Registered)}),
            {ok, #state{table = Artifacts, registry = Registry,
                        store = Registered, options = compile_options(Options),
                        loader = Loader},
             {continue, start}};
        {error, not_owner} ->
            {stop, {claim_failed, not_owner}}
    end.

%% Старт договаривается здесь, до первого обслуженного сообщения: сначала
%% читается загрузчик, если ему есть что сказать, затем досоздаются артефакты, у
%% которых документ есть, а артефакта нет, и только потом хранилище объявляет
%% себя готовым.
handle_continue(start, State0) ->
    State = load(State0),
    ok = repair(State),
    true = ets:insert(State#state.table, {ready, true}),
    {noreply, State}.

handle_call({add_schemas, Schemas}, _From, State) ->
    {Reply, Next} = add_schemas(Schemas, State),
    {reply, Reply, Next};
handle_call({add_entries, Entries}, _From, State) ->
    {Reply, Next} = add_entries(Entries, State),
    {reply, Reply, Next};
handle_call({remove, Uris}, _From, State) ->
    {Reply, Next} = remove_entries(Uris, State),
    {reply, Reply, Next};
%% Ответить на это сообщение управляющий может только договорив `handle_continue`,
%% и в этом весь ответ: другого состояния готовности у него нет.
handle_call(ready, _From, State) ->
    {reply, ok, State}.

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

%% Загрузчик читается один раз: на холодном старте и после потери реестра.
%% Отметка лежит в таблице реестра и потому переживает ровно те отказы, при
%% которых переживает и набор документов. Пустота реестра признаком не годится:
%% приложение вправе снять все документы, и возвращать их ему не за чем.
-spec load(#state{}) -> #state{}.
load(#state{loader = undefined} = State) ->
    State;
load(#state{registry = Registry} = State) ->
    case ets:member(Registry, loaded) of
        true  -> State;
        false -> load_documents(State)
    end.

%% Отказ загрузчика означает не ошибку вызывающего, а расхождение конфигурации:
%% нет каталога, испорчен файл, не сошлись ссылки. Поэтому падаем и отдаём
%% решение супервизору, вместо того чтобы поднять хранилище с дырой в наборе.
-spec load_documents(#state{}) -> #state{}.
load_documents(#state{loader = {Module, Args}} = State) ->
    case Module:load(Args) of
        {ok, Entries} ->
            case add_entries(Entries, State) of
                {{ok, _Names}, Loaded}    -> mark_loaded(Loaded);
                {{error, Reason}, _State} -> erlang:error({loader_failed, Reason})
            end;
        {error, Reason} ->
            erlang:error({loader_failed, Reason})
    end.

%% Отметка идёт следом за документами, а не тем же коммитом, и разрыв между ними
%% безвреден: смерть в этом промежутке приведёт к повторному чтению загрузчика, а
%% оно заменит те же документы теми же.
-spec mark_loaded(#state{}) -> #state{}.
mark_loaded(#state{registry = Registry} = State) ->
    true = ets:insert(Registry, {loaded, true}),
    State.

%% Пересобирается то, у чего документ есть, а артефакта нет: так выглядит
%% хранилище после перезапуска хранителя артефактов. Обратного расхождения не
%% бывает — таблица артефактов переживает только те отказы, при которых
%% переживает и таблица реестра.
%%
%% Отказ компиляции здесь означает не ошибку вызывающего, а расхождение внутри
%% хранилища: эти документы уже компилировались с теми же опциями. Поэтому
%% падаем и отдаём решение супервизору.
-spec repair(#state{}) -> ok.
repair(#state{table = Table, store = Store, options = Options} = State) ->
    case missing(Table, valid_json_store:canonical_names(Store)) of
        [] ->
            ok;
        Names ->
            {ok, Artifacts} = compile_all(Names, Store, Options),
            commit(State, Artifacts, [], [])
    end.

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

%% Первая ступень регистрации: схемы называют себя сами, и дальше идёт уже
%% обычный набор пар. Не выведенное имя останавливает вызов целиком — той же
%% ценой, что и негодное имя записи: регистрировать нечего.
-spec add_schemas([json()], #state{}) ->
          {{ok, [uri()]} | {error, add_error()}, #state{}}.
add_schemas(Schemas, #state{store = Store} = State) ->
    case valid_json_store:name_entries(Store, Schemas) of
        {ok, Entries}   -> add_entries(Entries, State);
        {error, Errors} -> {{error, {registration, Errors}}, State}
    end.

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
%% служебная строка с `base_uri` не попадает в перебор документов по устройству
%% ключа, а не по договорённости. Имя регистрации отдельным ключом не заводится —
%% оно есть полем документа, и обратно реестр собирает оба ключа сам.
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
%% она завершается badarg и обваливает старт хранилища громко. Тем же кончается
%% и хранилище без `base_uri`: им оно объявляет принадлежность своих схем
%% сервису, и назвать его умолчанием за разработчика нельзя.
-spec check_options([term()]) -> ok.
check_options(Options) when is_list(Options) ->
    case lists:keyfind(base_uri, 1, Options) of
        {base_uri, _Uri} -> known_options(Options);
        false            -> erlang:error(badarg, [Options])
    end;
check_options(Options) ->
    erlang:error(badarg, [Options]).

-spec known_options([term()]) -> ok.
known_options([]) ->
    ok;
known_options([{loader, {Module, _Args}} | Rest]) when is_atom(Module) ->
    known_options(Rest);
known_options([{Key, _Value} | Rest])
  when Key =:= base_uri; Key =:= default_dialect; Key =:= assert_format ->
    known_options(Rest);
known_options(Options) ->
    erlang:error(badarg, [Options]).

%% Негодное значение base_uri отвергнет сам реестр: правило допустимого
%% base_uri принадлежит ему.
-spec registry_options([store_option()]) -> [valid_json_store:registry_option()].
registry_options(Options) ->
    {base_uri, Uri} = lists:keyfind(base_uri, 1, Options),
    [{base_uri, Uri}].

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
