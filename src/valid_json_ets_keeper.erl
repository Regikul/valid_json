%% Хранитель таблицы артефактов одного хранилища. Он создаёт её, назначает heir
%% на себя и по запросу отдаёт владение управляющему. Больше он не делает
%% ничего, и малый объём работы здесь и есть механизм надёжности: хранитель
%% считается живым и стабильным именно потому, что ему нечем упасть —
%% компилятор, реестр и reload принадлежат управляющему, а таблица переживает
%% его перезапуск вместе с содержимым.
%%
%% Из этого следует правило для дальнейших правок: логика, способная отказать,
%% в хранитель не добавляется. Смерть самого хранителя схемой не покрывается —
%% heir окажется мёртвым, таблица потеряется, и восстановление сведётся к полной
%% пересборке.
-module(valid_json_ets_keeper).

-behaviour(gen_server).

-export([start_link/1, keeper_name/1, claim/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(GIFT, artifacts).

%% Имя хранилища служит и именем таблицы: хранилищ может быть несколько, и
%% каждое живёт в своей таблице под своим именем.
-spec start_link(atom()) -> {ok, pid()}.
start_link(Store) ->
    gen_server:start_link({local, keeper_name(Store)}, ?MODULE, Store, []).

%% Правило именования процесса живёт здесь, потому что под этим именем
%% регистрируется сам хранитель. Имена хранилищ приходят от приложения и никогда
%% из пользовательского ввода, поэтому пополнение таблицы атомов безопасно.
-spec keeper_name(atom()) -> atom().
keeper_name(Store) ->
    list_to_atom(atom_to_list(Store) ++ "_keeper").

%% Владение переходит в самом ets:give_away/3, поэтому вызывающему достаточно
%% дождаться ответа: 'ETS-TRANSFER' является только уведомлением. Повторный
%% вызов владельцем отвечает ok и таблицу не трогает; `not_owner` означает, что
%% таблицей владеет кто-то третий, и решение остаётся за вызывающим.
-spec claim(atom()) -> ok | {error, not_owner}.
claim(Store) ->
    gen_server:call(keeper_name(Store), claim).

init(Store) ->
    Store = ets:new(Store, [named_table,
                            set,
                            protected,
                            {read_concurrency, true},
                            {heir, self(), ?GIFT}]),
    {ok, Store}.

handle_call(claim, {Pid, _Tag}, Table) ->
    {reply, hand_over(Table, Pid), Table}.

handle_cast(_Message, Table) ->
    {noreply, Table}.

%% Управляющий умер, и таблица вернулась хранителю в момент его смерти. Это
%% сообщение только сообщает о случившемся и работы не требует.
handle_info({'ETS-TRANSFER', Table, _From, ?GIFT}, Table) ->
    {noreply, Table};
handle_info(_Message, Table) ->
    {noreply, Table}.

%% Единственная развилка в модуле, и она нужна затем, чтобы повторный claim не
%% превращался в badarg и не уносил таблицу вместе с хранителем: ets:give_away/3
%% разрешён только владельцу.
hand_over(Table, Pid) ->
    case ets:info(Table, owner) of
        Self when Self =:= self() ->
            true = ets:give_away(Table, Pid, ?GIFT),
            ok;
        Pid ->
            ok;
        _Other ->
            {error, not_owner}
    end.
