%% Управляющий одного хранилища. Он держит реестр документов и опции, владеет
%% таблицей артефактов и остаётся единственным, кто в неё пишет. Здесь же
%% собрано знание о том, что имя таблицы совпадает с именем хранилища.
%%
%% `lookup/2` — обычная функция, а не вызов: она исполняется в процессе
%% вызывающего, читает таблицу напрямую и управляющего не будит. Сообщением
%% идёт только запись, потому что путь холодный и сериализация на одном процессе
%% здесь как раз и нужна.
%%
%% Таблица переживает смерть управляющего по `heir`, а реестр — нет. Поэтому
%% после перезапуска читатели видят прежний набор артефактов, а реестр начинается
%% пустым: имена, которые приложение больше не добавит, останутся в таблице
%% сиротами. Чистить таблицу в `init` нельзя — ради переживания перезапуска вся
%% схема с хранителем и построена.
-module(valid_json_store_manager).

-behaviour(gen_server).

-include("valid_json_resources.hrl").

-export([start_link/2, manager_name/1, add/2, lookup/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([store_option/0]).

-type store_option() :: {base_uri, uri()}
                      | {default_dialect, dialect()}
                      | {assert_format, boolean()}.

-record(state, {
    table   :: atom(),
    store   :: store(),
    options :: [valid_json_compile:compile_option()]
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

%% Обе ветви ошибки списочные, а различает их тег, потому что имена в них значат
%% разное. У `registration` ключ — имя записи в написании вызывающего: до
%% артефактов дело не дошло, и канонического имени у отвергнутой записи может не
%% быть вовсе. У `compilation` ключ — каноническое имя, то самое, по которому
%% ходят в таблицу.
-spec add(atom(), [{uri(), json()}]) ->
          {ok, [uri()]}
        | {error, {registration, [{uri(), #schema_error{}}]}}
        | {error, {compilation, [{uri(), #schema_error{}}]}}.
add(Store, Entries) when is_list(Entries) ->
    gen_server:call(manager_name(Store), {add, Entries}).

-spec lookup(atom(), uri()) -> {ok, compiled()} | {error, not_found}.
lookup(Store, Uri) ->
    case ets:lookup(Store, Uri) of
        [{Uri, Compiled}] -> {ok, Compiled};
        []                -> {error, not_found}
    end.

%% Владение переходит в самом ets:give_away/3, поэтому ждать 'ETS-TRANSFER'
%% незачем: после ответа хранителя таблица уже наша. Отказ означает, что ею
%% владеет кто-то третий, а без владения писать всё равно нельзя.
init({Store, Options}) ->
    ok = check_options(Options),
    Registry = valid_json_store:new(registry_options(Options)),
    Compile = compile_options(Options),
    case valid_json_ets_keeper:claim(Store) of
        ok ->
            {ok, #state{table = Store, store = Registry, options = Compile}};
        {error, not_owner} ->
            {stop, {claim_failed, not_owner}}
    end.

handle_call({add, Entries}, _From, State) ->
    {Reply, Next} = add_entries(Entries, State),
    {reply, Reply, Next}.

handle_cast(_Message, State) ->
    {noreply, State}.

%% Уведомление о полученной таблице: работы оно не требует, потому что владение
%% перешло раньше, в ответе хранителя на claim.
handle_info({'ETS-TRANSFER', Table, _From, _Gift}, #state{table = Table} = State) ->
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.

%% Реестр меняется первым, но принимается только вместе с артефактами: до
%% успешной компиляции всего пересобираемого набора состояние остаётся прежним.
-spec add_entries([{uri(), json()}], #state{}) ->
          {{ok, [uri()]}
         | {error, {registration | compilation, [{uri(), #schema_error{}}]}},
           #state{}}.
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
                    commit(Table, Artifacts, Gone),
                    {{ok, Added}, State#state{store = Store1}};
                {error, Errors} ->
                    {{error, {compilation, Errors}}, State}
            end
    end.

%% Обратный индекс зависимостей не нужен: новый документ не может ни сломать, ни
%% починить чужой артефакт, потому что ссылающийся уже держал бы его в sources.
-spec affected(atom(), [uri()], [uri()]) -> [uri()].
affected(Table, Names, Changed) ->
    ordsets:from_list([Name || Name <- Names, stale(Table, Name, Changed)]).

-spec stale(atom(), uri(), [uri()]) -> boolean().
stale(Table, Name, Changed) ->
    case lookup(Table, Name) of
        {ok, #{sources := Sources}} ->
            ordsets:intersection(ordsets:from_list(Sources), Changed) =/= [];
        %% Имя реестра без артефакта — то расхождение с таблицей, какое остаётся
        %% после перезапуска управляющего. Пересборка его закрывает.
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

%% Порядок обязателен: список ets:insert/2 атомарен и изолирован для читателей,
%% а удаление этой гарантией не закрыто. Так снятое имя отвечает ещё некоторое
%% время после reload, но ложного not_found для живого имени не возникает.
-spec commit(atom(), [{uri(), compiled()}], [uri()]) -> ok.
commit(Table, Artifacts, Gone) ->
    true = ets:insert(Table, Artifacts),
    lists:foreach(fun(Name) -> true = ets:delete(Table, Name) end, Gone).

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
