%% Object applicators: спуск в подсхемы по свойствам объекта. `properties`,
%% `patternProperties` и `additionalProperties` свёрнуты компилятором в один
%% constraint, но каждый написанный keyword выпускает собственный unit и
%% собственную аннотацию (okf/architecture/validator-core.md, «Контракт
%% handler'а»). `propertyNames` стоит отдельно: он спускается к именам свойств.
-module(valid_json_object).

-include("valid_json_core.hrl").

-export([check/3]).

-type branch_location() :: properties | {pattern, binary()} |
                           additional_properties | property_names.

-spec check(constraint(), json(), #eval_context{}) -> #eval_result{}.
check({properties, Props, Patterns, Additional}, Instance, Context)
  when is_map(Instance) ->
    evaluate(Props, Patterns, Additional, Instance, Context);
%% Keywords применяются только к объекту: другое значение даёт успешный unit без
%% error и annotation, а не отказ.
check({properties, Props, Patterns, Additional}, _Instance, Context) ->
    inapplicable([{<<"properties">>, Props},
                  {<<"patternProperties">>, Patterns},
                  {<<"additionalProperties">>, Additional}], Context);
check({property_names, Addr}, Instance, Context) when is_map(Instance) ->
    names(Instance, Addr, Context);
check({property_names, Addr}, _Instance, Context) ->
    inapplicable([{<<"propertyNames">>, Addr}], Context).

%% Подсхема применяется к самому имени свойства, а не к его значению: вычисляемым
%% значением становится строка имени, а instance location указывает на свойство.
%% Аннотации keyword не производит и потому покрытия не вносит.
-spec names(#{binary() => json()}, addr(), #eval_context{}) -> #eval_result{}.
names(Instance, Addr, Context) ->
    Seed = valid_json_eval:empty_result(true),
    Applied = maps:fold(
                fun(Name, _Value, Result) ->
                        case stopped(Result, Context) of
                            true ->
                                Result;
                            false ->
                                valid_json_eval:conjoin_acc_discard_coverage(
                                  Result,
                                  branch(Addr, property_names, Name, Name, Context))
                        end
                end,
                Seed, Instance),
    case valid_json_eval:finish_acc(Applied) of
        #eval_result{valid = undefined} = Error ->
            Error#eval_result{evaluated = valid_json_evaluated:neutral(), units = []};
        #eval_result{valid = Valid, units = Units} ->
            #eval_result{valid     = Valid,
                         evaluated = valid_json_evaluated:neutral(),
                         units     = valid_json_unit:keyword_units(
                                       <<"propertyNames">>, Valid,
                                       name_detail(Valid), Units, Context)}
    end.

%% Аннотации у keyword нет, поэтому у успешного unit деталей тоже нет.
-spec name_detail(boolean()) -> detail().
name_detail(true)  -> none;
name_detail(false) -> {error, message(<<"propertyNames">>)}.

matches({_Source, Compiled}, Name) ->
    re:run(Name, Compiled, [{capture, none}]) =:= match.

%% Все три object keywords раскладываются за один обход map. Результаты и units
%% копятся раздельно, поэтому structural output сохраняет keyword-группы, а
%% additionalProperties использует уже известный факт совпадения, не повторяя
%% regex. В flag первый окончательный провал гасит работу оставшихся ветвей.
-spec evaluate(#{binary() => addr()} | undefined,
               [{regex(), addr()}] | undefined, addr() | undefined,
               #{binary() => json()}, #eval_context{}) -> #eval_result{}.
evaluate(undefined, undefined, undefined, _Instance, _Context) ->
    valid_json_eval:empty_result(true);
evaluate(Props, undefined, Additional, Instance,
         #eval_context{format = flag, need_coverage = false} = Context) ->
    Applied = maps:fold(
                fun(Name, Value, Result) ->
                        flag_plain_property(Name, Value, Props, Additional,
                                            Context, Result)
                end,
                valid_json_eval:empty_result(true), Instance),
    valid_json_eval:finish_acc(Applied);
evaluate(Props, Patterns, Additional, Instance,
         #eval_context{format = flag, need_coverage = false} = Context) ->
    %% Ни diagnostics, ни coverage этой границе не нужны: один accumulator
    %% сохраняет только conjunction verdict/error всех применившихся ветвей.
    Applied = maps:fold(
                fun(Name, Value, Result) ->
                        flag_property(Name, Value, Props, Patterns, Additional,
                                      Context, Result)
                end,
                valid_json_eval:empty_result(true), Instance),
    valid_json_eval:finish_acc(Applied);
evaluate(Props, undefined, Additional, Instance, Context) ->
    %% Самая частая форма не платит ни полем accumulator, ни вызовами за
    %% отсутствующий patternProperties.
    Empty = {valid_json_eval:empty_result(true), []},
    {_Halted, NamedApplied, AdditionalApplied} =
        maps:fold(
          fun(Name, Value, State) ->
                  plain_property(Name, Value, Props, Additional, Context, State)
          end,
          {false, Empty, Empty}, Instance),
    Named = written_result(<<"properties">>, Props, NamedApplied, Context),
    case stopped(Named, Context) of
        true ->
            Named;
        false ->
            valid_json_eval:conjoin(
              Named,
              written_result(<<"additionalProperties">>, Additional,
                             AdditionalApplied, Context))
    end;
evaluate(Props, Patterns, Additional, Instance, Context) ->
    Collect = collect_names(Context),
    Empty = {valid_json_eval:empty_result(true), []},
    {_Halted, NamedApplied, PatternedApplied, AdditionalApplied} =
        maps:fold(
          fun(Name, Value, State) ->
                  property(Name, Value, Props, Patterns, Additional,
                           Context, Collect, State)
          end,
          {false, Empty, Empty, Empty}, Instance),
    Named = written_result(<<"properties">>, Props, NamedApplied, Context),
    case stopped(Named, Context) of
        true ->
            Named;
        false ->
            Patterned = valid_json_eval:conjoin(
                          Named,
                          written_result(<<"patternProperties">>, Patterns,
                                         PatternedApplied, Context)),
            case stopped(Patterned, Context) of
                true ->
                    Patterned;
                false ->
                    valid_json_eval:conjoin(
                      Patterned,
                      written_result(<<"additionalProperties">>, Additional,
                                     AdditionalApplied, Context))
            end
    end.

plain_property(_Name, _Value, _Props, _Additional, _Context,
               {true, _Named, _AdditionalApplied} = State) ->
    State;
plain_property(Name, Value, undefined, Additional, Context,
               {false, Named, AdditionalApplied}) ->
    plain_after_named(false, Name, Value, Additional, Context,
                      Named, AdditionalApplied);
plain_property(Name, Value, Props, Additional, Context,
               {false, {Result, Names}, AdditionalApplied}) ->
    case maps:find(Name, Props) of
        error ->
            plain_after_named(false, Name, Value, Additional, Context,
                              {Result, Names}, AdditionalApplied);
        {ok, Addr} ->
            Merged = valid_json_eval:conjoin_acc_discard_coverage(
                       Result, branch(Addr, properties, Name, Value, Context)),
            plain_after_named(true, Name, Value, Additional, Context,
                              {Merged, [Name | Names]}, AdditionalApplied)
    end.

plain_after_named(IsNamed, Name, Value, Additional, Context,
                  {NamedResult, _Names} = Named, AdditionalApplied) ->
    case stopped(NamedResult, Context) of
        true ->
            {true, Named, AdditionalApplied};
        false ->
            NextAdditional = apply_additional(
                               Additional, IsNamed, Name, Value, Context, true,
                               AdditionalApplied),
            {AdditionalResult, _AdditionalNames} = NextAdditional,
            {stopped(AdditionalResult, Context), Named, NextAdditional}
    end.

flag_plain_property(_Name, _Value, _Props, _Additional, _Context,
                    #eval_result{valid = false} = Result) ->
    Result;
flag_plain_property(Name, Value, undefined, Additional, Context, Result) ->
    flag_plain_after_named(false, Name, Value, Additional, Context, Result);
flag_plain_property(Name, Value, Props, Additional, Context, Result) ->
    case maps:find(Name, Props) of
        error ->
            flag_plain_after_named(false, Name, Value, Additional,
                                   Context, Result);
        {ok, Addr} ->
            Merged = valid_json_eval:conjoin_acc_discard_coverage(
                       Result, branch(Addr, properties, Name, Value, Context)),
            flag_plain_after_named(true, Name, Value, Additional,
                                   Context, Merged)
    end.

flag_plain_after_named(IsNamed, Name, Value, Additional, Context, Result) ->
    case stopped(Result, Context) of
        true ->
            Result;
        false ->
            flag_additional(Additional, IsNamed, Name, Value, Context, Result)
    end.

flag_property(_Name, _Value, _Props, _Patterns, _Additional, _Context,
              #eval_result{valid = false} = Result) ->
    Result;
flag_property(Name, Value, Props, Patterns, Additional, Context, Result) ->
    {NamedResult, IsNamed} = flag_named(Props, Name, Value, Context, Result),
    case stopped(NamedResult, Context) of
        true ->
            NamedResult;
        false ->
            {PatternedResult, IsPatterned} =
                flag_patterned(Patterns, Name, Value, Context, NamedResult),
            case stopped(PatternedResult, Context) of
                true ->
                    PatternedResult;
                false ->
                    flag_additional(Additional, IsNamed orelse IsPatterned,
                                    Name, Value, Context, PatternedResult)
            end
    end.

flag_named(undefined, _Name, _Value, _Context, Result) ->
    {Result, false};
flag_named(Props, Name, Value, Context, Result) ->
    case maps:find(Name, Props) of
        error ->
            {Result, false};
        {ok, Addr} ->
            {valid_json_eval:conjoin_acc_discard_coverage(
               Result, branch(Addr, properties, Name, Value, Context)), true}
    end.

flag_patterned(undefined, _Name, _Value, _Context, Result) ->
    {Result, false};
flag_patterned(Patterns, Name, Value, Context, Result) ->
    apply_patterns(Patterns, Name, Value, Context, Result, false).

flag_additional(undefined, _Covered, _Name, _Value, _Context, Result) ->
    Result;
flag_additional(_Addr, true, _Name, _Value, _Context, Result) ->
    Result;
flag_additional(Addr, false, Name, Value, Context, Result) ->
    valid_json_eval:conjoin_acc_discard_coverage(
      Result, branch(Addr, additional_properties, Name, Value, Context)).

-spec property(binary(), json(), #{binary() => addr()} | undefined,
               [{regex(), addr()}] | undefined, addr() | undefined,
               #eval_context{}, boolean(),
               {boolean(), {#eval_result{}, [binary()]},
                {#eval_result{}, [binary()]}, {#eval_result{}, [binary()]}}) ->
          {boolean(), {#eval_result{}, [binary()]},
           {#eval_result{}, [binary()]}, {#eval_result{}, [binary()]}}.
property(_Name, _Value, _Props, _Patterns, _Additional, _Context, _Collect,
         {true, _Named, _Patterned, _AdditionalApplied} = State) ->
    State;
property(Name, Value, Props, Patterns, Additional, Context, Collect,
         {false, Named, Patterned, AdditionalApplied}) ->
    {NextNamed, IsNamed} = apply_named(
                              Props, Name, Value, Context, Collect, Named),
    {NamedResult, _NamedNames} = NextNamed,
    case stopped(NamedResult, Context) of
        true ->
            {true, NextNamed, Patterned, AdditionalApplied};
        false ->
            {NextPatterned, IsPatterned} = apply_patterned(
                                               Patterns, Name, Value, Context,
                                               Collect, Patterned),
            {PatternedResult, _PatternedNames} = NextPatterned,
            case stopped(PatternedResult, Context) of
                true ->
                    {true, NextNamed, NextPatterned, AdditionalApplied};
                false ->
                    NextAdditional = apply_additional(
                                       Additional, IsNamed orelse IsPatterned,
                                       Name, Value, Context, Collect,
                                       AdditionalApplied),
                    {AdditionalResult, _AdditionalNames} = NextAdditional,
                    {stopped(AdditionalResult, Context),
                     NextNamed, NextPatterned, NextAdditional}
            end
    end.

apply_named(undefined, _Name, _Value, _Context, _Collect, Applied) ->
    {Applied, false};
apply_named(Props, Name, Value, Context, Collect, {Result, Names} = Applied) ->
    case maps:find(Name, Props) of
        error ->
            {Applied, false};
        {ok, Addr} ->
            Merged = valid_json_eval:conjoin_acc_discard_coverage(
                       Result, branch(Addr, properties, Name, Value, Context)),
            {{Merged, remember(Name, Names, Collect)}, true}
    end.

apply_patterned(undefined, _Name, _Value, _Context, _Collect, Applied) ->
    {Applied, false};
apply_patterned(Patterns, Name, Value, Context, Collect, {Result, Names}) ->
    {Merged, Matched} = apply_patterns(
                           Patterns, Name, Value, Context, Result, false),
    Remembered = case Matched of
                     true  -> remember(Name, Names, Collect);
                     false -> Names
                 end,
    {{Merged, Remembered}, Matched}.

%% Совпавших паттернов может быть несколько, и применяется каждый. Имя при этом
%% запоминается один раз, без последующей `usort`.
-spec apply_patterns([{regex(), addr()}], binary(), json(), #eval_context{},
                     #eval_result{}, boolean()) -> {#eval_result{}, boolean()}.
apply_patterns([], _Name, _Value, _Context, Result, Matched) ->
    {Result, Matched};
apply_patterns([{{Source, _} = Regex, Addr} | Rest], Name, Value, Context,
               Result, Matched) ->
    case matches(Regex, Name) of
        false ->
            apply_patterns(Rest, Name, Value, Context, Result, Matched);
        true ->
            Merged = valid_json_eval:conjoin_acc_discard_coverage(
                       Result,
                       branch(Addr, {pattern, Source}, Name, Value, Context)),
            case stopped(Merged, Context) of
                true  -> {Merged, true};
                false -> apply_patterns(Rest, Name, Value, Context, Merged, true)
            end
    end.

apply_additional(undefined, _Covered, _Name, _Value, _Context, _Collect,
                 Applied) ->
    Applied;
apply_additional(_Addr, true, _Name, _Value, _Context, _Collect, Applied) ->
    Applied;
apply_additional(Addr, false, Name, Value, Context, Collect, {Result, Names}) ->
    Merged = valid_json_eval:conjoin_acc_discard_coverage(
               Result,
               branch(Addr, additional_properties, Name, Value, Context)),
    {Merged, remember(Name, Names, Collect)}.

written_result(_Keyword, undefined, _Applied, _Context) ->
    valid_json_eval:empty_result(true);
written_result(Keyword, _Slot, Applied, Context) ->
    keyword_result(Keyword, Applied, Context).

%% Аннотация называет каждое применённое имя один раз. Порядок обхода map не
%% является контрактом, поэтому отдельной сортировки здесь нет.
-spec keyword_result(binary(), {#eval_result{}, [binary()]}, #eval_context{}) ->
          #eval_result{}.
keyword_result(_Keyword,
               {#eval_result{valid = undefined} = Error, _Names}, _Context) ->
    Error#eval_result{evaluated = valid_json_evaluated:neutral(), units = []};
keyword_result(_Keyword, {#eval_result{valid = Valid}, _Names},
               #eval_context{format = flag, need_coverage = false}) ->
    valid_json_eval:empty_result(Valid);
keyword_result(_Keyword, {#eval_result{valid = Valid}, Names},
               #eval_context{format = flag} = Context) ->
    #eval_result{valid = Valid,
                 evaluated = coverage(Valid, Names, Context),
                 units = []};
keyword_result(Keyword, {#eval_result{valid = Valid, units = Units}, Names}, Context) ->
    #eval_result{valid     = Valid,
                 evaluated = coverage(Valid, Names, Context),
                 units     = valid_json_unit:keyword_units(
                               Keyword, Valid,
                               detail(Keyword, Valid, Names),
                               Units, Context)}.

collect_names(#eval_context{format = flag, need_coverage = false}) -> false;
collect_names(#eval_context{}) -> true.

remember(Name, Names, true) -> [Name | Names];
remember(_Name, Names, false) -> Names.

stopped(#eval_result{valid = false}, #eval_context{format = flag}) -> true;
stopped(#eval_result{}, #eval_context{}) -> false.

-spec coverage(boolean(), [binary()], #eval_context{}) -> evaluated().
coverage(_Valid, _Applied, #eval_context{need_coverage = false}) ->
    valid_json_evaluated:neutral();
coverage(true, Applied, #eval_context{}) ->
    valid_json_evaluated:properties(Applied);
coverage(false, _Applied, #eval_context{}) ->
    valid_json_evaluated:neutral().

%% Родитель покрывает имя свойства, а не то, что нашлось внутри значения.
%% Ветка получает `need_coverage = false`: покрытие дочерней schema принадлежит
%% ей самой. В формате flag не строятся ненаблюдаемые стеки локаций.
-spec branch(addr(), branch_location(), binary(), json(), #eval_context{}) ->
          #eval_result{}.
branch(Addr, _Location, _Name, Value,
       #eval_context{format = flag,
                     instance_location = {Depth, _Instance}} = Context) ->
    valid_json_eval:eval_child_at(
      Addr, Value, [], {Depth + 1, []}, false, Context);
branch(Addr, Location, Name, Value, Context) ->
    #eval_context{keyword_location = Keywords,
                  instance_location = {Depth, Instance}} = Context,
    valid_json_eval:eval_child_at(
      Addr, Value, branch_keywords(Location, Name, Keywords),
      {Depth + 1, [Name | Instance]}, false, Context).

-spec branch_keywords(branch_location(), binary(), [binary()]) -> [binary()].
branch_keywords(properties, Name, Keywords) ->
    [Name, <<"properties">> | Keywords];
branch_keywords({pattern, Source}, _Name, Keywords) ->
    [Source, <<"patternProperties">> | Keywords];
branch_keywords(additional_properties, _Name, Keywords) ->
    [<<"additionalProperties">> | Keywords];
branch_keywords(property_names, _Name, Keywords) ->
    [<<"propertyNames">> | Keywords].

-spec detail(binary(), boolean(), [binary()]) -> detail().
detail(_Keyword, true, Applied) -> {annotation, Applied};
detail(Keyword, false, _Applied) -> {error, message(Keyword)}.

-spec message(binary()) -> binary().
message(<<"properties">>) ->
    <<"object properties do not match their schemas">>;
message(<<"patternProperties">>) ->
    <<"object properties do not match their pattern schemas">>;
message(<<"additionalProperties">>) ->
    <<"additional object properties do not match the schema">>;
message(<<"propertyNames">>) ->
    <<"object property names do not match the schema">>.

-spec inapplicable([{binary(), term()}], #eval_context{}) -> #eval_result{}.
inapplicable(_Slots, #eval_context{format = flag}) ->
    valid_json_eval:empty_result(true);
inapplicable(Slots, Context) ->
    Units = lists:append(
              [valid_json_unit:keyword_units(
                 Keyword, true, none, [], Context)
               || {Keyword, Slot} <- Slots, Slot =/= undefined]),
    #eval_result{valid = true,
                 evaluated = valid_json_evaluated:neutral(),
                 units = Units}.
