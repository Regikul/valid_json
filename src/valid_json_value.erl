%% Модель JSON-значения: предикаты типов над термами json:decode/1.
%% Нормативное описание — okf/architecture/validator-core.md, раздел
%% «Модель JSON-значения».
-module(valid_json_value).

-include("valid_json_core.hrl").

-export([is_type/2, is_multiple_of/2,
         is_length_at_most/2, is_length_at_least/2, is_unique/1]).

%% type: "integer" принимает любой number с нулевой дробной частью, поэтому
%% integer не сводится к is_integer/1.
-spec is_type(json_type(), json()) -> boolean().
is_type(null,    V) -> V =:= null;
is_type(boolean, V) -> is_boolean(V);
is_type(object,  V) -> is_map(V);
is_type(array,   V) -> is_list(V);
is_type(string,  V) -> is_binary(V);
is_type(number,  V) -> is_number(V);
is_type(integer, V) -> is_integer(V) orelse (is_float(V) andalso V == trunc(V)).

%% minLength и maxLength считают Unicode code points, а не байты, UTF-16 units
%% или grapheme clusters (validation.txt:385). Границы byte_size div 4 =< CP =<
%% byte_size часто дают ответ, и тогда строку обходить не нужно.
-spec is_length_at_most(binary(), non_neg_integer()) -> boolean().
is_length_at_most(String, Bound) when byte_size(String) =< Bound ->
    true;
is_length_at_most(String, Bound) when byte_size(String) div 4 > Bound ->
    false;
is_length_at_most(String, Bound) ->
    cp_length(String) =< Bound.

-spec is_length_at_least(binary(), non_neg_integer()) -> boolean().
is_length_at_least(String, Bound) when byte_size(String) div 4 >= Bound ->
    true;
is_length_at_least(String, Bound) when byte_size(String) < Bound ->
    false;
is_length_at_least(String, Bound) ->
    cp_length(String) >= Bound.

%% Обход тотален: декодер гарантирует корректный UTF-8.
-spec cp_length(binary()) -> non_neg_integer().
cp_length(String) ->
    cp_length(String, 0).

cp_length(<<>>, Count)                    -> Count;
cp_length(<<_/utf8, Rest/binary>>, Count) -> cp_length(Rest, Count + 1).

%% uniqueItems держится на той же JSON equality, что const и enum. Проверка
%% квадратична; линейная допустима только через канонизацию чисел, не меняющую
%% значения аннотаций.
-spec is_unique([json()]) -> boolean().
is_unique([]) ->
    true;
is_unique([Item | Rest]) ->
    not lists:any(fun(Other) -> Other == Item end, Rest) andalso is_unique(Rest).

%% Гибрид из validator-core.md, раздел «Точность чисел»: два целых считаются
%% через rem, конечное частное сравнивается с round/1, а переполнение деления
%% уводит на точное сравнение дробей. Делитель положителен: это проверяет
%% компилятор.
-spec is_multiple_of(number(), number()) -> boolean().
is_multiple_of(Value, Divisor) when is_integer(Value), is_integer(Divisor) ->
    Value rem Divisor =:= 0;
is_multiple_of(Value, Divisor) ->
    try Value / Divisor of
        Quotient -> Quotient == round(Quotient)
    catch
        error:badarith -> exact_multiple_of(Value, Divisor)
    end.

%% Точный путь нужен, когда частное не представимо double: например
%% 1.0e308 при multipleOf 0.123456789. Обе дроби конечны, поэтому вопрос
%% сводится к делимости целых.
-spec exact_multiple_of(number(), number()) -> boolean().
exact_multiple_of(Value, Divisor) ->
    {ValueNum, ValueDen}     = fraction(Value),
    {DivisorNum, DivisorDen} = fraction(Divisor),
    (ValueNum * DivisorDen) rem (ValueDen * DivisorNum) =:= 0.

%% Каждый IEEE-754 double точно равен p / 2^q, поэтому дробь строится из
%% полей представления без потери точности. Inf и NaN декодер не порождает.
-spec fraction(number()) -> {integer(), pos_integer()}.
fraction(Value) when is_integer(Value) ->
    {Value, 1};
fraction(Value) when is_float(Value) ->
    <<Sign:1, Exponent:11, Mantissa:52>> = <<Value/float>>,
    {Magnitude, Power} =
        case Exponent of
            0 -> {Mantissa, 1074};                       % субнормальное значение
            _ -> {Mantissa + (1 bsl 52), 1075 - Exponent}
        end,
    Numerator = case Sign of 0 -> Magnitude; 1 -> -Magnitude end,
    case Power >= 0 of
        true  -> {Numerator, 1 bsl Power};
        false -> {Numerator bsl (-Power), 1}
    end.
