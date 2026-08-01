%% Модель JSON-значения: предикаты типов над термами json:decode/1.
%% Нормативное описание — okf/architecture/validator-core.md, раздел
%% «Модель JSON-значения».
-module(valid_json_value).

-include("valid_json_core.hrl").

-export([is_type/2, is_multiple_of/2]).

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
