%% Обработчики чистых assertions. Handler видит constraint, значение и контекст;
%% схему, dialect и registry он не читает. Контракт описан в
%% okf/architecture/validator-core.md, раздел «Контракт handler'а».
-module(valid_json_assert).

-include("valid_json_core.hrl").

-export([check/3]).

%% Вердикт и его изложение разделены: holds/2 отвечает на вопрос схемы, report/4
%% превращает ответ в результат вычисления. Сообщение строится только при
%% провале и на `valid` с `evaluated` не влияет.
-spec check(constraint(), json(), #eval_context{}) -> #eval_result{}.
check(Constraint, Instance, Context) ->
    report(Constraint, holds(Constraint, Instance), Instance, Context).

%% JSON equality есть Erlang ==: оно рекурсивно, считает 1 и 1.0 равными и не
%% смешивает boolean с number. Поэтому lists:member/2 здесь неприменим.
-spec holds(constraint(), json()) -> boolean().
holds({type, Types}, Instance) ->
    lists:any(fun(Type) -> valid_json_value:is_type(Type, Instance) end, Types);
holds({enum, Values}, Instance) ->
    lists:any(fun(Value) -> Value == Instance end, Values);
holds({const, Value}, Instance) ->
    Value == Instance;
holds({multiple_of, Divisor}, Instance) ->
    number(fun(Number) -> valid_json_value:is_multiple_of(Number, Divisor) end, Instance);
holds({maximum, Bound}, Instance) ->
    number(fun(Number) -> Number =< Bound end, Instance);
holds({exclusive_maximum, Bound}, Instance) ->
    number(fun(Number) -> Number < Bound end, Instance);
holds({minimum, Bound}, Instance) ->
    number(fun(Number) -> Number >= Bound end, Instance);
holds({exclusive_minimum, Bound}, Instance) ->
    number(fun(Number) -> Number > Bound end, Instance);
holds({pattern, {_Source, Compiled}}, Instance) ->
    string(fun(Text) -> re:run(Text, Compiled, [{capture, none}]) =:= match end, Instance);
holds({max_length, Bound}, Instance) ->
    string(fun(Text) -> valid_json_value:is_length_at_most(Text, Bound) end, Instance);
holds({min_length, Bound}, Instance) ->
    string(fun(Text) -> valid_json_value:is_length_at_least(Text, Bound) end, Instance);
holds({max_items, Bound}, Instance) ->
    array(fun(Items) -> length(Items) =< Bound end, Instance);
holds({min_items, Bound}, Instance) ->
    array(fun(Items) -> length(Items) >= Bound end, Instance);
%% uniqueItems: false остаётся в IR и выпускает собственный unit, поэтому
%% no-op вычисляется, а не выбрасывается компилятором.
holds({unique_items, false}, _Instance) ->
    true;
holds({unique_items, true}, Instance) ->
    array(fun valid_json_value:is_unique/1, Instance);
holds({max_properties, Bound}, Instance) ->
    object(fun(Object) -> map_size(Object) =< Bound end, Instance);
holds({min_properties, Bound}, Instance) ->
    object(fun(Object) -> map_size(Object) >= Bound end, Instance);
holds({required, Names}, Instance) ->
    object(fun(Object) -> missing(Names, Object) =:= [] end, Instance);
holds({dependent_required, Dependencies}, Instance) ->
    object(fun(Object) -> missing_dependents(Dependencies, Object) =:= [] end, Instance).

%% Keyword ограничивает только свой тип instance: значение другого типа проходит
%% успешно, а не отвергается. Сравнение чисел в Erlang точно и через границу
%% integer/float, поэтому 300 и 300.0 остаются одной точкой.
-spec number(fun((number()) -> boolean()), json()) -> boolean().
number(Check, Instance) when is_number(Instance) -> Check(Instance);
number(_Check, _Instance)                        -> true.

%% То же правило применимости для строк. Instance приходит из json:decode/1 и
%% потому является корректным UTF-8, что и требует unicode-режим движка.
-spec string(fun((binary()) -> boolean()), json()) -> boolean().
string(Check, Instance) when is_binary(Instance) -> Check(Instance);
string(_Check, _Instance)                        -> true.

-spec array(fun(([json()]) -> boolean()), json()) -> boolean().
array(Check, Instance) when is_list(Instance) -> Check(Instance);
array(_Check, _Instance)                      -> true.

-spec object(fun((#{binary() => json()}) -> boolean()), json()) -> boolean().
object(Check, Instance) when is_map(Instance) -> Check(Instance);
object(_Check, _Instance)                     -> true.

-spec missing([binary()], #{binary() => json()}) -> [binary()].
missing(Names, Object) ->
    [Name || Name <- Names, not maps:is_key(Name, Object)].

%% Требование включается только для имён, которые в instance действительно есть.
-spec missing_dependents(#{binary() => [binary()]}, #{binary() => json()}) -> [binary()].
missing_dependents(Dependencies, Object) ->
    Triggered = maps:filter(fun(Name, _) -> maps:is_key(Name, Object) end, Dependencies),
    lists:usort(missing(lists:append(maps:values(Triggered)), Object)).

%% Чистые assertions не вносят покрытия. Flag не собирает units вовсе, а
%% successful assertion не виден ни в Basic, ни в Detailed: у него нет detail
%% или descendants. Verbose сохраняет такой silent result.
-spec report(constraint(), boolean(), json(), #eval_context{}) -> #eval_result{}.
report(_Constraint, Valid, _Instance, #eval_context{format = flag}) ->
    valid_json_eval:empty_result(Valid);
report(_Constraint, true, _Instance, #eval_context{format = basic}) ->
    valid_json_eval:empty_result(true);
report(_Constraint, true, _Instance, #eval_context{format = detailed}) ->
    valid_json_eval:empty_result(true);
report(Constraint, Valid, Instance, Context) ->
    Units = valid_json_unit:keyword_units(
              keyword(Constraint), Valid,
              detail(Constraint, Valid, Instance), [], Context),
    #eval_result{valid = Valid, evaluated = valid_json_evaluated:neutral(), units = Units}.

-spec detail(constraint(), boolean(), json()) -> detail().
detail(_Constraint, true, _Instance) -> none;
detail(Constraint, false, Instance)  -> {error, message(Constraint, Instance)}.

%% Тег IR не совпадает с именем keyword, а составной constraint отвечает сразу
%% за несколько имён. Поэтому unit называет keyword явно.
-spec keyword(constraint()) -> binary().
keyword({type, _})               -> <<"type">>;
keyword({enum, _})               -> <<"enum">>;
keyword({const, _})              -> <<"const">>;
keyword({multiple_of, _})        -> <<"multipleOf">>;
keyword({maximum, _})            -> <<"maximum">>;
keyword({exclusive_maximum, _})  -> <<"exclusiveMaximum">>;
keyword({minimum, _})            -> <<"minimum">>;
keyword({exclusive_minimum, _})  -> <<"exclusiveMinimum">>;
keyword({max_length, _})         -> <<"maxLength">>;
keyword({min_length, _})         -> <<"minLength">>;
keyword({pattern, _})            -> <<"pattern">>;
keyword({max_items, _})          -> <<"maxItems">>;
keyword({min_items, _})          -> <<"minItems">>;
keyword({unique_items, _})       -> <<"uniqueItems">>;
keyword({max_properties, _})     -> <<"maxProperties">>;
keyword({min_properties, _})     -> <<"minProperties">>;
keyword({required, _})           -> <<"required">>;
keyword({dependent_required, _}) -> <<"dependentRequired">>.

%% Сообщение называет нарушенное требование, а не отвергнутое значение: печать
%% произвольного instance стоила бы дороже самой проверки. Suite сообщений не
%% закрепляет, поэтому текст остаётся политикой реализации.
%% Клаузы для `{unique_items, false}` нет: этот constraint не может провалиться.
-spec message(constraint(), json()) -> binary().
message({type, Types}, Instance) ->
    Got = atom_to_binary(valid_json_value:type_of(Instance), utf8),
    <<"expected ", (alternatives(Types))/binary, ", got ", Got/binary>>;
message({enum, _Values}, _Instance) ->
    <<"value is not one of the enumerated values">>;
message({const, _Value}, _Instance) ->
    <<"value is not equal to the constant">>;
message({multiple_of, Divisor}, _Instance) ->
    <<"value is not a multiple of ", (number_text(Divisor))/binary>>;
message({maximum, Bound}, _Instance) ->
    <<"value is greater than the maximum ", (number_text(Bound))/binary>>;
message({exclusive_maximum, Bound}, _Instance) ->
    <<"value is not less than the exclusive maximum ", (number_text(Bound))/binary>>;
message({minimum, Bound}, _Instance) ->
    <<"value is less than the minimum ", (number_text(Bound))/binary>>;
message({exclusive_minimum, Bound}, _Instance) ->
    <<"value is not greater than the exclusive minimum ", (number_text(Bound))/binary>>;
message({max_length, Bound}, _Instance) ->
    <<"string is longer than ", (number_text(Bound))/binary, " characters">>;
message({min_length, Bound}, _Instance) ->
    <<"string is shorter than ", (number_text(Bound))/binary, " characters">>;
message({pattern, {Source, _Compiled}}, _Instance) ->
    <<"string does not match pattern ", Source/binary>>;
message({max_items, Bound}, _Instance) ->
    <<"array has more than ", (number_text(Bound))/binary, " items">>;
message({min_items, Bound}, _Instance) ->
    <<"array has fewer than ", (number_text(Bound))/binary, " items">>;
message({unique_items, true}, _Instance) ->
    <<"array items are not unique">>;
message({max_properties, Bound}, _Instance) ->
    <<"object has more than ", (number_text(Bound))/binary, " properties">>;
message({min_properties, Bound}, _Instance) ->
    <<"object has fewer than ", (number_text(Bound))/binary, " properties">>;
message({required, Names}, Instance) ->
    absent(missing(Names, Instance));
message({dependent_required, Dependencies}, Instance) ->
    absent(missing_dependents(Dependencies, Instance)).

-spec absent([binary()]) -> binary().
absent([Name]) ->
    <<"object is missing required property ", (quoted(Name))/binary>>;
absent(Names) ->
    <<"object is missing required properties ", (join(Names))/binary>>.

-spec join([binary()]) -> binary().
join(Names) ->
    iolist_to_binary(lists:join(<<", ">>, [quoted(Name) || Name <- Names])).

-spec quoted(binary()) -> binary().
quoted(Name) ->
    <<$", Name/binary, $">>.

%% `type: []` метасхема запрещает, но компилятор доводит его до IR как всякое
%% написанное значение, поэтому сообщение существует и для пустого списка.
-spec alternatives([json_type()]) -> binary().
alternatives([]) ->
    <<"no type">>;
alternatives(Types) ->
    iolist_to_binary(lists:join(<<" or ">>,
                                 [atom_to_binary(Type, utf8) || Type <- Types])).

%% Число печатается в форме, из которой читается обратно: у float это кратчайшее
%% представление, а не округление ~p.
-spec number_text(number()) -> binary().
number_text(Value) when is_integer(Value) -> integer_to_binary(Value);
number_text(Value) when is_float(Value)   -> float_text(Value).

-ifdef(CAP_FLOAT_TO_BINARY_SHORT).
float_text(Value) ->
    erlang:float_to_binary(Value, [short]).

-else.

float_text(Value) ->
    list_to_binary(normalize_short_float(
                     lists:flatten(io_lib:write(Value,
                                                [{float_format, short}])))).

normalize_short_float(Text) ->
    case exponent_position(Text, 1) of
        0 -> Text;
        Position ->
            {Mantissa, ExponentText} = lists:split(Position - 1, Text),
            Exponent = list_to_integer(tl(ExponentText)),
            {Sign, Unsigned} = case Mantissa of
                                   [$- | Rest] -> {[$-], Rest};
                                   [$+ | Rest] -> {[$+], Rest};
                                   _            -> {[], Mantissa}
                               end,
            DotPosition = dot_position(Unsigned, 1),
            Digits = [C || C <- Unsigned, C =/= $.],
            Sign ++ trim_fraction(move_decimal(Digits,
                                                DotPosition + Exponent))
    end.

exponent_position([], _Position) -> 0;
exponent_position([$e | _], Position) -> Position;
exponent_position([$E | _], Position) -> Position;
exponent_position([_ | Rest], Position) ->
    exponent_position(Rest, Position + 1).

dot_position([], Position) -> Position - 1;
dot_position([$. | _], Position) -> Position - 1;
dot_position([_ | Rest], Position) -> dot_position(Rest, Position + 1).

move_decimal(Digits, Position) when Position =< 0 ->
    "0." ++ lists:duplicate(-Position, $0) ++ Digits;
move_decimal(Digits, Position) when Position >= length(Digits) ->
    Digits ++ lists:duplicate(Position - length(Digits), $0);
move_decimal(Digits, Position) ->
    {Left, Right} = lists:split(Position, Digits),
    Left ++ "." ++ Right.

trim_fraction(Text) ->
    case lists:splitwith(fun(C) -> C =/= $. end, Text) of
        {_Integer, [_Dot | Fraction]} ->
            Trimmed = trim_right_zeros(Fraction),
            case Trimmed of
                [] -> lists:sublist(Text, length(Text) - length(Fraction) - 1);
                _  -> lists:sublist(Text, length(Text) - length(Fraction)) ++ Trimmed
            end;
        _NoFraction ->
            Text
    end.

trim_right_zeros(Text) ->
    lists:reverse(lists:dropwhile(fun(C) -> C =:= $0 end,
                                  lists:reverse(Text))).

-endif.
