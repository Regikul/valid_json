%% Дерево одного хранилища. Стратегия rest_for_one выбрана ради порядка
%% «хранители перед управляющим»: управляющий забирает у них таблицы, поэтому
%% переживать их смерть в одиночку не может. Обратное неверно — хранители смерть
%% управляющего переживают, и таблицы возвращаются к ним по `heir` вместе с
%% содержимым.
%%
%% Это не только порядок старта. Смерть хранителя таблицу не убивает: ею владеет
%% управляющий, и теряется лишь heir, а новый хранитель упал бы на `ets:new` под
%% занятым именем. Спасает ровно rest_for_one: вместе с хранителем гасится и
%% управляющий, при его остановке таблица уходит к мёртвому heir и уничтожается,
%% и хранитель создаёт её заново.
%%
%% Отсюда и порядок между хранителями: первым стоит реестр. Его смерть
%% пересобирает всё, а смерть хранителя артефактов оставляет реестр целым, и
%% артефакты по нему восстанавливаются. Обратный порядок оставлял бы реестр
%% пустым при живых артефактах, то есть ровно то расхождение, ради устранения
%% которого реестр и переехал в таблицу.
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
    Registry = valid_json_ets_keeper:child_spec(
                 valid_json_store_manager:registry_table(Store),
                 valid_json_store_manager:table_options(registry)),
    Artifacts = valid_json_ets_keeper:child_spec(
                  valid_json_store_manager:artifacts_table(Store),
                  valid_json_store_manager:table_options(artifacts)),
    Manager = #{id => valid_json_store_manager,
                start => {valid_json_store_manager, start_link, [Store, Options]},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [valid_json_store_manager]},
    {ok, {#{strategy => rest_for_one, intensity => 1, period => 5},
          [Registry, Artifacts, Manager]}}.
