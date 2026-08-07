%% Object applicators: спуск в подсхемы по свойствам объекта. `properties`,
%% `patternProperties` и `additionalProperties` свёрнуты компилятором в один
%% constraint, но каждый написанный keyword выпускает собственный unit и
%% собственную аннотацию (okf/architecture/validator-core.md, «Контракт
%% handler'а»). `propertyNames` стоит отдельно: он спускается к именам свойств.
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
                  {<<"additionalProperties">>, Additional}], Context);
check({property_names, Addr}, Instance, Context) when is_map(Instance) ->
    names(lists:sort(maps:keys(Instance)), Addr, Context);
check({property_names, Addr}, _Instance, Context) ->
    inapplicable([{<<"propertyNames">>, Addr}], Context).

%% Подсхема применяется к самому имени свойства, а не к его значению: вычисляемым
%% значением становится строка имени, а instance location указывает на свойство.
%% Аннотации keyword не производит и потому покрытия не вносит: для
%% `unevaluatedProperties` имя остаётся непокрытым.
-spec names([binary()], addr(), #eval_context{}) -> #eval_result{}.
names(Names, Addr, Context) ->
    case scan(Names, Addr, Context,
              #eval_result{valid = true,
                           evaluated = valid_json_evaluated:neutral(),
                           units = []}) of
        #eval_result{valid = undefined} = Error ->
            Error#eval_result{evaluated = valid_json_evaluated:neutral(), units = []};
        #eval_result{valid = Valid, units = Units} ->
            #eval_result{valid     = Valid,
                         evaluated = valid_json_evaluated:neutral(),
                         units     = valid_json_unit:keyword_units(
                                       <<"propertyNames">>, Valid,
                                       name_detail(Valid), Units, Context)}
    end.

-spec scan([binary()], addr(), #eval_context{}, #eval_result{}) -> #eval_result{}.
scan([], _Addr, _Context, Result) ->
    valid_json_eval:finish_acc(Result);
scan([Name | Rest], Addr, Context, Result) ->
    Merged = valid_json_eval:conjoin_acc(
               Result,
               branch(Addr, [<<"propertyNames">>], Name, Name, Context)),
    case Merged#eval_result.valid =:= false andalso
         Context#eval_context.format =:= flag of
        true  -> valid_json_eval:finish_acc(Merged);
        false -> scan(Rest, Addr, Context, Merged)
    end.

%% Аннотации у keyword нет, поэтому у успешного unit деталей тоже нет.
-spec name_detail(boolean()) -> detail().
name_detail(true)  -> none;
name_detail(false) -> {error, message(<<"propertyNames">>)}.

-spec covered(#{binary() => addr()} | undefined, [{regex(), addr()}] | undefined,
              [binary()]) -> [binary()].
covered(Props, Patterns, Names) ->
    [Name || Name <- Names, is_named(Props, Name) orelse is_patterned(Patterns, Name)].

is_named(undefined, _Name) -> false;
is_named(Props, Name)      -> maps:is_key(Name, Props).

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
     || Name <- Names, maps:is_key(Name, Props)].

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

evaluate([], _Instance, _Context, Result) ->
    Result;
evaluate([{_Keyword, undefined} | Rest], Instance, Context, Result) ->
    evaluate(Rest, Instance, Context, Result);
evaluate([{Keyword, Applications} | Rest], Instance, Context, Result) ->
    Merged = valid_json_eval:conjoin(
               Result, keyword(Keyword, Applications, Instance, Context)),
    case Merged#eval_result.valid =:= false andalso Context#eval_context.format =:= flag of
        true  -> Merged;
        false -> evaluate(Rest, Instance, Context, Merged)
    end.

%% Аннотация называет имена, к которым keyword применился. Провалившийся keyword
%% аннотации не производит, поэтому и покрытия не вносит.
-spec keyword(binary(), [application()], json(), #eval_context{}) -> #eval_result{}.
keyword(Keyword, Applications, Instance, Context) ->
    {AppliedResult, Names} =
        apply_all(Applications, Instance, Context,
                  #eval_result{valid = true,
                               evaluated = valid_json_evaluated:neutral(),
                               units = []}, []),
    case AppliedResult of
        #eval_result{valid = undefined} = Error ->
            Error#eval_result{evaluated = valid_json_evaluated:neutral(), units = []};
        #eval_result{valid = Valid, units = Units} ->
            Applied = lists:usort(Names),
            #eval_result{valid     = Valid,
                         evaluated = coverage(Valid, Applied),
                         units     = valid_json_unit:keyword_units(
                                       Keyword, Valid,
                                       detail(Keyword, Valid, Applied),
                                       Units, Context)}
    end.

-spec coverage(boolean(), [binary()]) -> evaluated().
coverage(true, Applied) -> valid_json_evaluated:properties(Applied);
coverage(false, _Applied) -> valid_json_evaluated:neutral().

%% Родитель покрывает имя свойства, а не то, что нашлось внутри значения:
%% наверх идут имена применённых свойств, а не покрытие их подсхем.
-spec apply_all([application()], json(), #eval_context{}, #eval_result{},
                [binary()]) -> {#eval_result{}, [binary()]}.
apply_all([], _Instance, _Context, Result, Names) ->
    {valid_json_eval:finish_acc(Result), lists:reverse(Names)};
apply_all([{Tail, Name, Addr} | Rest], Instance, Context, Result, Names) ->
    Merged = valid_json_eval:conjoin_acc(
               Result,
               branch(Addr, Tail, Name, maps:get(Name, Instance), Context)),
    case Merged#eval_result.valid =:= false andalso
         Context#eval_context.format =:= flag of
        true  -> {valid_json_eval:finish_acc(Merged), lists:reverse([Name | Names])};
        false -> apply_all(Rest, Instance, Context, Merged, [Name | Names])
    end.

%% Локация keyword следует схеме, локация инстанса — значению: имя свойства
%% двигает второй стек, а сегменты первого зависят от применившегося keyword.
%% Флаг `coverage` при спуске гаснет: покрытие дочерней schema принадлежит ей
%% самой (validator-core.md, «Контекст и cycle guard»).
-spec branch(addr(), [binary()], binary(), json(), #eval_context{}) -> #eval_result{}.
branch(Addr, Tail, Name, Value, Context) ->
    #eval_context{keyword_location = Keywords,
                  instance_location = {Depth, Instance}} = Context,
    Nested = Context#eval_context{keyword_location  = Tail ++ Keywords,
                                  instance_location = {Depth + 1, [Name | Instance]},
                                  coverage          = false},
    valid_json_eval:eval(Addr, Value, Nested).

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
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []};
inapplicable(Slots, Context) ->
    Units = [valid_json_unit:keyword(Keyword, true, none, Context)
             || {Keyword, Slot} <- Slots, Slot =/= undefined],
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = Units}.
