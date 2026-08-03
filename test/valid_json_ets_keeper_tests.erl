-module(valid_json_ets_keeper_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

-define(DIALECT, <<"https://json-schema.org/draft/2020-12/schema">>).
-define(FIRST, valid_json_test_store_one).
-define(SECOND, valid_json_test_store_two).

%% Таблицы именованные, поэтому eunit_wrapper_/1 с inparallel здесь не объявлен:
%% проверки идут по одной, а содержимое между ними снимается
%% ets:delete_all_objects/1.
keeper_test_() ->
    {setup,
     fun start_keepers/0,
     fun stop_keepers/1,
     fun(Keepers) ->
             [{"layout и роли таблицы",     fun() -> layout(Keepers) end},
              {"claim передаёт владение",   fun() -> claim(Keepers) end},
              {"последовательные claim",    fun() -> repeated_claim(Keepers) end},
              {"claim у каждого свой",      fun() -> claim_per_store(Keepers) end},
              {"lookup промаха",            fun() -> lookup_missing(Keepers) end},
              {"lookup артефакта",          fun() -> lookup_hit(Keepers) end},
              {"хранилища не видят друг друга", fun() -> stores_apart(Keepers) end},
              {"чтение из чужого процесса", fun() -> foreign_reader(Keepers) end}]
     end}.

start_keepers() ->
    {ok, First} = valid_json_ets_keeper:start_link(?FIRST),
    {ok, Second} = valid_json_ets_keeper:start_link(?SECOND),
    #{?FIRST => First, ?SECOND => Second}.

stop_keepers(Keepers) ->
    lists:foreach(fun stop_keeper/1, maps:keys(Keepers)).

stop_keeper(Store) ->
    ok = gen_server:stop(valid_json_ets_keeper:keeper_name(Store)),
    case ets:info(Store, owner) of
        undefined                 -> ok;
        Self when Self =:= self() -> true = ets:delete(Store), ok;
        _Other                    -> ok
    end.

%% Проверка идёт до первого claim, поэтому владелец и heir здесь совпадают.
layout(Keepers) ->
    Keeper = keeper(?FIRST, Keepers),
    ?assertEqual(set, ets:info(?FIRST, type)),
    ?assertEqual(protected, ets:info(?FIRST, protection)),
    ?assertEqual(true, ets:info(?FIRST, named_table)),
    ?assertEqual(true, ets:info(?FIRST, read_concurrency)),
    ?assertEqual(false, ets:info(?FIRST, write_concurrency)),
    ?assertEqual(1, ets:info(?FIRST, keypos)),
    ?assertEqual(Keeper, ets:info(?FIRST, owner)),
    ?assertEqual(Keeper, ets:info(?FIRST, heir)).

claim(Keepers) ->
    own(?FIRST, Keepers),
    ?assertEqual(self(), ets:info(?FIRST, owner)),
    ?assertEqual(keeper(?FIRST, Keepers), ets:info(?FIRST, heir)).

%% Повторный claim не должен ни менять владельца, ни ронять хранителя, а
%% посторонний при живом владельце получает отказ и оставляет хранителя
%% отвечающим на следующие вызовы.
repeated_claim(Keepers) ->
    own(?FIRST, Keepers),
    ?assertEqual(ok, valid_json_ets_keeper:claim(?FIRST)),
    ?assertEqual(self(), ets:info(?FIRST, owner)),
    ?assertEqual({error, not_owner},
                 in_process(fun() -> valid_json_ets_keeper:claim(?FIRST) end)),
    ?assertEqual(self(), ets:info(?FIRST, owner)),
    ?assertEqual(ok, valid_json_ets_keeper:claim(?FIRST)),
    ?assert(is_process_alive(keeper(?FIRST, Keepers))).

%% Взятое владение относится к одному хранилищу: второе остаётся у своего
%% хранителя, пока его не попросили отдельно.
claim_per_store(Keepers) ->
    own(?FIRST, Keepers),
    ?assertEqual(keeper(?SECOND, Keepers), ets:info(?SECOND, owner)),
    own(?SECOND, Keepers),
    ?assertEqual(self(), ets:info(?FIRST, owner)),
    ?assertEqual(self(), ets:info(?SECOND, owner)).

lookup_missing(Keepers) ->
    own(?FIRST, Keepers),
    ?assertEqual({error, not_found},
                 valid_json_store_manager:lookup(?FIRST,
                                              <<"https://example.com/missing">>)).

lookup_hit(Keepers) ->
    own(?FIRST, Keepers),
    Uri = <<"https://example.com/schema">>,
    Artifact = artifact(Uri, true),
    true = ets:insert(?FIRST, {Uri, Artifact}),
    ?assertEqual({ok, Artifact}, valid_json_store_manager:lookup(?FIRST, Uri)).

%% Хранилища разделены целиком: один и тот же uri в двух таблицах хранит разные
%% артефакты, и запись в одну не видна в другой.
stores_apart(Keepers) ->
    own(?FIRST, Keepers),
    own(?SECOND, Keepers),
    Uri = <<"https://example.com/schema">>,
    Other = <<"https://example.com/other">>,
    true = ets:insert(?FIRST, {Uri, artifact(Uri, true)}),
    true = ets:insert(?SECOND, {Uri, artifact(Uri, false)}),
    true = ets:insert(?SECOND, {Other, artifact(Other, true)}),
    ?assertEqual({ok, artifact(Uri, true)},
                 valid_json_store_manager:lookup(?FIRST, Uri)),
    ?assertEqual({ok, artifact(Uri, false)},
                 valid_json_store_manager:lookup(?SECOND, Uri)),
    ?assertEqual({error, not_found}, valid_json_store_manager:lookup(?FIRST, Other)).

%% Клиент по контракту вызывается из любого процесса, а не только у владельца
%% таблицы.
foreign_reader(Keepers) ->
    own(?FIRST, Keepers),
    Uri = <<"https://example.com/schema">>,
    Artifact = artifact(Uri, true),
    true = ets:insert(?FIRST, {Uri, Artifact}),
    ?assertEqual({ok, Artifact},
                 in_process(fun() ->
                                    valid_json_store_manager:lookup(?FIRST, Uri)
                            end)).

keeper(Store, Keepers) ->
    maps:get(Store, Keepers).

%% Владение забирается один раз на процесс: пока проверки идут в одном
%% процессе, повторный claim ему не нужен.
own(Store, Keepers) ->
    Keeper = keeper(Store, Keepers),
    case ets:info(Store, owner) of
        Self when Self =:= self() -> ok;
        Keeper                    -> ok = valid_json_ets_keeper:claim(Store)
    end,
    true = ets:delete_all_objects(Store),
    Store.

in_process(Fun) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() -> Parent ! {Ref, Fun()} end),
    Result = receive
                 {Ref, Value} -> Value
             after 1000 ->
                 erlang:error(no_result)
             end,
    receive
        {'DOWN', Monitor, process, Pid, normal} -> Result
    after 1000 ->
        erlang:error(reader_alive)
    end.

artifact(Uri, RootNode) ->
    #{root => Uri,
      sources => [Uri],
      resources =>
          #{Uri => #resource{id = Uri,
                             dialect = ?DIALECT,
                             anchors = #{},
                             dynamic_anchors = #{},
                             nodes = #{<<>> => RootNode}}}}.
