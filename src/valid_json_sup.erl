%% Корень библиотеки. Первой стоит ветка встроенных метасхем: без неё компиляция
%% схемы не идёт, и к моменту старта хранилищ таблица должна быть полна. Дальше
%% идут сами хранилища, и падение одного не касается остальных, поэтому стратегия
%% one_for_one. Порядок внутри хранилища — забота valid_json_store_sup.
%%
%% rest_for_one здесь был бы неверен: он гасил бы вместе с метасхемами и
%% хранилища с их хранителями, а это потеря всех зарегистрированных схем ради
%% редкого события. Порядок нужен только на старте, и one_for_one его даёт.
%%
%% Стандартное хранилище поднимается всегда: приложению, которому хватает одного
%% набора схем, ничего заводить не нужно. `base_uri` ему называется здесь, потому
%% что опций ему передать неоткуда: дерево поднимает сама библиотека.
-module(valid_json_sup).

-behaviour(supervisor).

-include("valid_json_resources.hrl").

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Metaschema = #{id => valid_json_metaschema_sup,
                   start => {valid_json_metaschema_sup, start_link, []},
                   restart => permanent,
                   shutdown => infinity,
                   type => supervisor,
                   modules => [valid_json_metaschema_sup]},
    Standard = valid_json_store_sup:child_spec(
                 ?STANDARD_STORE, [{base_uri, ?STANDARD_BASE_URI}]),
    {ok, {#{strategy => one_for_one, intensity => 1, period => 5},
          [Metaschema, Standard]}}.
