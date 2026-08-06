%% Ветка встроенных метасхем. Устроена как дерево хранилища и по той же причине:
%% таблицей владеет рабочий процесс, а переживает его смерть она у хранителя по
%% `heir`.
%%
%% Стратегия rest_for_one задаёт порядок «хранитель перед владельцем». Владелец
%% забирает таблицу у хранителя и пережить его смерть в одиночку не может:
%% таблица осталась бы с мёртвым heir, а новый хранитель упал бы на `ets:new`
%% под занятым именем. Спасает rest_for_one: вместе с хранителем гасится и
%% владелец, при его остановке таблица уходит к мёртвому heir и уничтожается, и
%% хранитель создаёт её заново. Обратное неверно — смерть одного владельца
%% таблицу не рушит, и перезапущенный находит bundle на месте.
%%
%% Имени у этого процесса нет намеренно: держит его родитель, а обращаться к
%% нему некому.
-module(valid_json_metaschema_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link(?MODULE, []).

init([]) ->
    Table = valid_json_metaschema:table(),
    Keeper = #{id => Table,
               start => {valid_json_ets_keeper, start_link,
                         [Table, valid_json_metaschema:table_options()]},
               restart => permanent,
               shutdown => 5000,
               type => worker,
               modules => [valid_json_ets_keeper]},
    Owner = #{id => valid_json_metaschema_owner,
              start => {valid_json_metaschema, start_link, []},
              restart => permanent,
              shutdown => 5000,
              type => worker,
              modules => [valid_json_metaschema]},
    {ok, {#{strategy => rest_for_one, intensity => 1, period => 5},
          [Keeper, Owner]}}.
