%% Object applicators. `properties`, `patternProperties` и `additionalProperties`
%% свёрнуты компилятором в один constraint, но каждый написанный keyword
%% выпускает собственный unit и собственную аннотацию
%% (okf/architecture/validator-core.md, «Контракт handler'а»).
-module(valid_json_object).

-include("valid_json_core.hrl").

-export([check/3]).

%% Применение: сегменты keyword location, имя свойства и адрес дочерней schema.
%% Имя нужно отдельно от сегментов, потому что оно двигает другой стек.
-type application() :: {[binary()], binary(), addr()}.

-spec check(constraint(), json(), #eval_context{}) -> #eval_result{}.
check({properties, Props, Patterns, Additional}, Instance, Context) when is_map(Instance) ->
    Names = lists:sort(maps:keys(Instance)),
    %% Остаток считается по статически сохранённым именам и паттернам, а не по
    %% аннотациям соседей: общего накопителя у составного constraint нет.
    Rest = Names -- covered(Props, Patterns, Names),
    evaluate([{<<"properties">>, named(Props, Names)},
              {<<"patternProperties">>, patterned(Patterns, Names)},
              {<<"additionalProperties">>, additional(Additional, Rest)}],
             Instance, Context);
%% Keywords применяются только к объекту: другое значение даёт успешный unit без
%% error и annotation, а не отказ.
check({properties, Props, Patterns, Additional}, _Instance, Context) ->
    inapplicable([{<<"properties">>, Props},
                  {<<"patternProperties">>, Patterns},
                  {<<"additionalProperties">>, Additional}], Context).

-spec covered(#{binary() => addr()} | undefined, [{regex(), addr()}] | undefined,
              [binary()]) -> [binary()].
covered(Props, Patterns, Names) ->
    [Name || Name <- Names, is_named(Props, Name) orelse is_patterned(Patterns, Name)].

is_named(undefined, _Name) -> false;
is_named(Props, Name)      -> is_map_key(Name, Props).

is_patterned(undefined, _Name) ->
    false;
is_patterned(Patterns, Name) ->
    lists:any(fun({Regex, _Addr}) -> matches(Regex, Name) end, Patterns).

matches({_Source, Compiled}, Name) ->
    re:run(Name, Compiled, [{capture, none}]) =:= match.

%% Ненаписанный keyword применений не даёт и unit не выпускает; написанный с
%% пустым результатом остаётся и даёт пустую аннотацию.
-spec named(#{binary() => addr()} | undefined, [binary()]) -> [application()] | undefined.
named(undefined, _Names) ->
    undefined;
named(Props, Names) ->
    [{[Name, <<"properties">>], Name, maps:get(Name, Props)}
     || Name <- Names, is_map_key(Name, Props)].

%% Совпавших паттернов может быть несколько, и применяется каждый: сегмент
%% локации берётся из исходного текста паттерна, а не из имени свойства.
-spec patterned([{regex(), addr()}] | undefined, [binary()]) -> [application()] | undefined.
patterned(undefined, _Names) ->
    undefined;
patterned(Patterns, Names) ->
    [{[Source, <<"patternProperties">>], Name, Addr}
     || Name <- Names, {{Source, _} = Regex, Addr} <- Patterns, matches(Regex, Name)].

%% Своего сегмента у ветви нет: она стоит на самом keyword.
-spec additional(addr() | undefined, [binary()]) -> [application()] | undefined.
additional(undefined, _Rest) ->
    undefined;
additional(Addr, Rest) ->
    [{[<<"additionalProperties">>], Name, Addr} || Name <- Rest].

%% Обрыв разрешён только в режиме flag; в остальных режимах выполняются все три
%% keyword'а, потому что дерево units должно быть полным.
-spec evaluate([{binary(), [application()] | undefined}], json(), #eval_context{}) ->
          #eval_result{}.
evaluate(Written, Instance, Context) ->
    evaluate(Written, Instance, Context,
             #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []}).

evaluate([], _Instance, _Context, #eval_result{units = Units} = Result) ->
    Result#eval_result{units = lists:reverse(Units)};
evaluate([{_Keyword, undefined} | Rest], Instance, Context, Result) ->
    evaluate(Rest, Instance, Context, Result);
evaluate([{Keyword, Applications} | Rest], Instance, Context,
         #eval_result{valid = Valid, evaluated = Evaluated, units = Units}) ->
    #eval_result{valid = ValidOne, evaluated = EvaluatedOne, units = UnitsOne} =
        keyword(Keyword, Applications, Instance, Context),
    Merged = #eval_result{valid     = Valid andalso ValidOne,
                          evaluated = valid_json_evaluated:merge(Evaluated, EvaluatedOne),
                          units     = lists:reverse(UnitsOne, Units)},
    case Merged#eval_result.valid =:= false andalso Context#eval_context.mode =:= flag of
        true  -> Merged#eval_result{units = lists:reverse(Merged#eval_result.units)};
        false -> evaluate(Rest, Instance, Context, Merged)
    end.

%% Аннотация называет имена, к которым keyword применился. Провалившийся keyword
%% аннотации не производит, поэтому и покрытия не вносит.
-spec keyword(binary(), [application()], json(), #eval_context{}) -> #eval_result{}.
keyword(Keyword, Applications, Instance, Context) ->
    {Valid, Names, Units} = apply_all(Applications, Instance, Context, true, [], []),
    Applied = lists:usort(Names),
    #eval_result{valid     = Valid,
                 evaluated = coverage(Valid, Applied),
                 units     = own(Keyword, Valid, Applied, Context) ++ Units}.

-spec coverage(boolean(), [binary()]) -> evaluated().
coverage(true, Applied) -> valid_json_evaluated:properties(Applied);
coverage(false, _Applied) -> valid_json_evaluated:neutral().

%% Покрытие дочерней schema принадлежит ей самой и наверх не идёт: родитель
%% покрывает имя свойства, а не то, что нашлось внутри значения.
-spec apply_all([application()], json(), #eval_context{}, boolean(), [binary()],
                [#output_unit{}]) -> {boolean(), [binary()], [#output_unit{}]}.
apply_all([], _Instance, _Context, Valid, Names, Units) ->
    {Valid, Names, lists:reverse(Units)};
apply_all([{Tail, Name, Addr} | Rest], Instance, Context, Valid, Names, Units) ->
    #eval_result{valid = ValidOne, units = UnitsOne} =
        branch(Addr, Tail, Name, maps:get(Name, Instance), Context),
    Accumulated = Valid andalso ValidOne,
    Collected = lists:reverse(UnitsOne, Units),
    case Accumulated =:= false andalso Context#eval_context.mode =:= flag of
        true  -> {false, [Name | Names], lists:reverse(Collected)};
        false -> apply_all(Rest, Instance, Context, Accumulated, [Name | Names], Collected)
    end.

%% Локация keyword следует схеме, локация инстанса — значению: имя свойства
%% двигает второй стек, а сегменты первого зависят от применившегося keyword.
-spec branch(addr(), [binary()], binary(), json(), #eval_context{}) -> #eval_result{}.
branch(Addr, Tail, Name, Value, Context) ->
    #eval_context{keyword_location = Keywords, instance_location = Instance} = Context,
    Nested = Context#eval_context{keyword_location  = Tail ++ Keywords,
                                  instance_location = [Name | Instance]},
    valid_json_eval:eval(Addr, Value, Nested).

%% В режиме flag units не собираются вовсе: ответ исчерпывается вердиктом.
-spec own(binary(), boolean(), [binary()], #eval_context{}) -> [#output_unit{}].
own(_Keyword, _Valid, _Applied, #eval_context{mode = flag}) ->
    [];
own(Keyword, Valid, Applied, Context) ->
    [valid_json_unit:keyword(Keyword, Valid, detail(Keyword, Valid, Applied), Context)].

-spec detail(binary(), boolean(), [binary()]) -> detail().
detail(_Keyword, true, Applied) -> {annotation, Applied};
detail(Keyword, false, _Applied) -> {error, message(Keyword)}.

-spec message(binary()) -> binary().
message(<<"properties">>) ->
    <<"object properties do not match their schemas">>;
message(<<"patternProperties">>) ->
    <<"object properties do not match their pattern schemas">>;
message(<<"additionalProperties">>) ->
    <<"additional object properties do not match the schema">>.

-spec inapplicable([{binary(), term()}], #eval_context{}) -> #eval_result{}.
inapplicable(_Slots, #eval_context{mode = flag}) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []};
inapplicable(Slots, Context) ->
    Units = [valid_json_unit:keyword(Keyword, true, none, Context)
             || {Keyword, Slot} <- Slots, Slot =/= undefined],
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = Units}.
