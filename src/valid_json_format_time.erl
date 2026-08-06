%% Алгоритмы четырёх format attributes, заданных RFC 3339: `date`, `time`,
%% `date-time` и `duration`. Модуль отвечает только на вопрос о строке; таблица,
%% которая его зовёт, и обе роли keyword живут в valid_json_format. Границы
%% каждого алгоритма зафиксированы в okf/architecture/format-attributes.md.
-module(valid_json_format_time).

-export([date/1, time/1, date_time/1, duration/1]).

%% Правило `full-date` (RFC 3339, раздел 5.6): ровно четыре цифры года, две
%% месяца и две дня через дефис. Длину месяца и високосный год считает
%% calendar:valid_date/3 — григорианское правило совпадает с требуемым вплоть до
%% вековых лет, и она же отвергает нулевой месяц и нулевой день.
-spec date(binary()) -> boolean().
date(<<Year:4/binary, $-, Month:2/binary, $-, Day:2/binary>>) ->
    case {digits(Year), digits(Month), digits(Day)} of
        {{ok, Y}, {ok, M}, {ok, D}} -> calendar:valid_date(Y, M, D);
        _Other                      -> false
    end;
date(_Other) ->
    false.

%% Правило `full-time`: `partial-time` и обязательный offset. Offset снимается с
%% хвоста, потому что `Z` и `±HH:MM` — единственные его формы, а без него строка
%% неверна целиком.
-spec time(binary()) -> boolean().
time(String) ->
    case offset(String) of
        {ok, Partial, Minutes} -> partial_time(Partial, Minutes);
        error                  -> false
    end.

%% `date-time` — `full-date`, разделитель и `full-time`. Разделитель берётся
%% одиннадцатым байтом, а не поиском `T`: длина даты постоянна, и искать нечего.
-spec date_time(binary()) -> boolean().
date_time(<<Date:10/binary, Separator, Time/binary>>) when Separator =:= $T;
                                                           Separator =:= $t ->
    date(Date) andalso time(Time);
date_time(_Other) ->
    false.

%% ABNF `duration` (RFC 3339, Appendix A). Вложенность правил строгая, поэтому
%% units сочетаются не любые, а только идущие подряд: `P1M2D` верно, а `P1Y2D`
%% нет — за годами по ABNF следует лишь месяц.
-spec duration(binary()) -> boolean().
duration(<<$P, $T, Time/binary>>) ->
    dur_time(Time);
duration(<<$P, Date/binary>>) ->
    dur_date(Date) orelse dur_week(Date);
duration(_Other) ->
    false.

%% Смещение возвращается в минутах со знаком: по нему решается допустимость leap
%% second. `-00:00` — законная запись неизвестного локального смещения и от
%% `+00:00` арифметикой не отличается.
-spec offset(binary()) -> {ok, binary(), integer()} | error.
offset(String) ->
    Size = byte_size(String),
    case Size of
        0 ->
            error;
        _ ->
            case binary:last(String) of
                Zulu when Zulu =:= $Z; Zulu =:= $z ->
                    {ok, binary:part(String, 0, Size - 1), 0};
                _Other when Size < 6 ->
                    error;
                _Other ->
                    Offset = binary:part(String, Size - 6, 6),
                    case Offset of
                        <<Sign, Hour:2/binary, $:, Minute:2/binary>>
                          when Sign =:= $+; Sign =:= $- ->
                            numoffset(binary:part(String, 0, Size - 6),
                                      Sign, digits(Hour), digits(Minute));
                        _OtherOffset ->
                            error
                    end
            end
    end.

-spec numoffset(binary(), byte(), {ok, non_neg_integer()} | error,
                {ok, non_neg_integer()} | error) -> {ok, binary(), integer()} | error.
numoffset(Partial, $+, {ok, Hour}, {ok, Minute}) when Hour =< 23, Minute =< 59 ->
    {ok, Partial, Hour * 60 + Minute};
numoffset(Partial, $-, {ok, Hour}, {ok, Minute}) when Hour =< 23, Minute =< 59 ->
    {ok, Partial, -(Hour * 60 + Minute)};
numoffset(_Partial, _Sign, _Hour, _Minute) ->
    error.

%% `partial-time`: по две цифры на час, минуту и секунду плюс необязательная
%% дробь. Секунду 60 разбирает отдельное правило.
-spec partial_time(binary(), integer()) -> boolean().
partial_time(<<Hour:2/binary, $:, Minute:2/binary, $:, Second:2/binary,
               Fraction/binary>>, Offset) ->
    case {digits(Hour), digits(Minute), digits(Second)} of
        {{ok, H}, {ok, M}, {ok, S}} when H =< 23, M =< 59 ->
            secfrac(Fraction) andalso second(S, H, M, Offset);
        _Other ->
            false
    end;
partial_time(_Partial, _Offset) ->
    false.

%% `time-secfrac` — точка и хотя бы одна цифра. Запятая ISO 8601 сюда не
%% годится, а посторонний хвост после дроби не годится тем более.
-spec secfrac(binary()) -> boolean().
secfrac(<<>>) ->
    true;
secfrac(<<$., Fraction/binary>>) ->
    digits(Fraction) =/= error;
secfrac(_Other) ->
    false.

%% Leap second допускается ровно в последнюю минуту суток UTC (RFC 3339, раздел
%% 5.7), поэтому секунда 60 проверяется не по местному времени, а по
%% приведённому смещением: `01:29:60+01:30` верно, а `23:59:60+01:00` нет.
-spec second(non_neg_integer(), non_neg_integer(), non_neg_integer(), integer()) ->
          boolean().
second(Second, _Hour, _Minute, _Offset) when Second =< 59 ->
    true;
second(60, Hour, Minute, Offset) ->
    ((Hour * 60 + Minute - Offset) rem 1440 + 1440) rem 1440 =:= 23 * 60 + 59;
second(_Second, _Hour, _Minute, _Offset) ->
    false.

%% `dur-date` — последовательность из years, months и days, за которой может
%% идти `dur-time`.
-spec dur_date(binary()) -> boolean().
dur_date(Binary) ->
    case sequence(Binary, "YMD") of
        {ok, <<>>}                -> true;
        {ok, <<$T, Time/binary>>} -> dur_time(Time);
        _Other                    -> false
    end.

-spec dur_time(binary()) -> boolean().
dur_time(Binary) ->
    sequence(Binary, "HMS") =:= {ok, <<>>}.

%% `dur-week` не сочетается ни с чем и составляет всю строку целиком.
-spec dur_week(binary()) -> boolean().
dur_week(Binary) ->
    unit(Binary) =:= {ok, $W, <<>>}.

%% Обе тройки units устроены ABNF одинаково: последовательность начинается с
%% любого из них, но продолжается только непосредственно следующим.
-spec sequence(binary(), [byte()]) -> {ok, binary()} | error.
sequence(Binary, Units) ->
    case unit(Binary) of
        {ok, Unit, Rest} ->
            case lists:splitwith(fun(Other) -> Other =/= Unit end, Units) of
                {_Skipped, [Unit | Next]} -> sequence_tail(Rest, Next);
                {_All, []}                -> error
            end;
        error ->
            error
    end.

%% Хвост последовательности вправе оборваться в любом месте, но перескочить
%% через unit не вправе. Начало `dur-time` возвращается вызывающему: разбирать
%% его этой же тройкой нельзя.
-spec sequence_tail(binary(), [byte()]) -> {ok, binary()} | error.
sequence_tail(<<>>, _Next) ->
    {ok, <<>>};
sequence_tail(<<$T, _Time/binary>> = Rest, _Next) ->
    {ok, Rest};
sequence_tail(Binary, [Unit | Next]) ->
    case unit(Binary) of
        {ok, Unit, Rest} -> sequence_tail(Rest, Next);
        _Other           -> error
    end;
sequence_tail(_Binary, []) ->
    error.

%% Элемент ABNF — `1*DIGIT` и буква unit. Сама буква здесь не проверяется: её
%% место в последовательности решает вызывающий.
-spec unit(binary()) -> {ok, byte(), binary()} | error.
unit(<<Digit, Rest/binary>>) when Digit >= $0, Digit =< $9 ->
    unit_tail(Rest);
unit(_Other) ->
    error.

-spec unit_tail(binary()) -> {ok, byte(), binary()} | error.
unit_tail(<<Digit, Rest/binary>>) when Digit >= $0, Digit =< $9 ->
    unit_tail(Rest);
unit_tail(<<Unit, Rest/binary>>) ->
    {ok, Unit, Rest};
unit_tail(<<>>) ->
    error.

%% Цифры только ASCII: ABNF RFC 3339 знает единственное правило DIGIT. Пустую
%% строку функция не принимает и потому годится и для элементов `duration`, где
%% ABNF требует `1*DIGIT`.
-spec digits(binary()) -> {ok, non_neg_integer()} | error.
digits(<<Digit, Rest/binary>>) when Digit >= $0, Digit =< $9 ->
    digits(Rest, Digit - $0);
digits(_Other) ->
    error.

-spec digits(binary(), non_neg_integer()) -> {ok, non_neg_integer()} | error.
digits(<<>>, Value) ->
    {ok, Value};
digits(<<Digit, Rest/binary>>, Value) when Digit >= $0, Digit =< $9 ->
    digits(Rest, Value * 10 + Digit - $0);
digits(_Other, _Value) ->
    error.
