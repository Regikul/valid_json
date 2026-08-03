%% Дерево одного хранилища. Стратегия rest_for_one выбрана ради порядка
%% «хранитель перед управляющим»: управляющий забирает таблицу у хранителя,
%% поэтому переживать его смерть в одиночку не может. Обратное неверно —
%% хранитель смерть управляющего переживает, и таблица возвращается к нему по
%% `heir` вместе с содержимым.
%%
%% Приложение, которому нужно собственное хранилище, берёт отсюда child_spec/2 и
%% ставит его в своё дерево. Стандартное хранилище библиотека поднимает сама, без
%% опций: их значения оно берёт из app env либо из встроенных умолчаний.
%%
%% Имени у этого процесса нет намеренно: держит его родитель, а обращаться к нему
%% пока некому. Имя появится тогда, когда понадобится, а не заранее.
-module(valid_json_store_sup).

-behaviour(supervisor).

-export([start_link/1, start_link/2, child_spec/1, child_spec/2, init/1]).

-spec child_spec(atom()) -> supervisor:child_spec().
child_spec(Store) ->
    child_spec(Store, []).

-spec child_spec(atom(), [valid_json_store_manager:store_option()]) ->
          supervisor:child_spec().
child_spec(Store, Options) ->
    #{id => Store,
      start => {?MODULE, start_link, [Store, Options]},
      restart => permanent,
      shutdown => infinity,
      type => supervisor,
      modules => [?MODULE]}.

-spec start_link(atom()) -> {ok, pid()}.
start_link(Store) ->
    start_link(Store, []).

-spec start_link(atom(), [valid_json_store_manager:store_option()]) ->
          {ok, pid()}.
start_link(Store, Options) ->
    supervisor:start_link(?MODULE, {Store, Options}).

init({Store, Options}) ->
    Keeper = #{id => valid_json_ets_keeper,
               start => {valid_json_ets_keeper, start_link, [Store]},
               restart => permanent,
               shutdown => 5000,
               type => worker,
               modules => [valid_json_ets_keeper]},
    Manager = #{id => valid_json_store_manager,
                start => {valid_json_store_manager, start_link, [Store, Options]},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [valid_json_store_manager]},
    {ok, {#{strategy => rest_for_one, intensity => 1, period => 5},
          [Keeper, Manager]}}.
