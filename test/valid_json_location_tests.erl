%% Печать локаций. Стек обратный, поэтому голова списка — последний добавленный
%% сегмент, и в указателе она стоит справа.
-module(valid_json_location_tests).

-include_lib("eunit/include/eunit.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

pointer_test_() ->
    [?_assertEqual(<<>>, valid_json_location:pointer([])),
     ?_assertEqual(<<"/type">>, valid_json_location:pointer([<<"type">>])),
     ?_assertEqual(<<"/properties/a/type">>,
                   valid_json_location:pointer([<<"type">>, <<"a">>, <<"properties">>])),
     %% Пустое имя свойства — допустимый сегмент, а не отсутствие сегмента.
     ?_assertEqual(<<"/">>, valid_json_location:pointer([<<>>])),
     ?_assertEqual(<<"//a">>, valid_json_location:pointer([<<"a">>, <<>>])),
     %% Индексы массива приходят готовыми сегментами.
     ?_assertEqual(<<"/items/0">>,
                   valid_json_location:pointer([<<"0">>, <<"items">>]))].

%% "~" кодируется первым, иначе "~1" в имени свойства стало бы косой чертой.
escaping_test_() ->
    [?_assertEqual(<<"/~0a~1b">>, valid_json_location:pointer([<<"~a/b">>])),
     ?_assertEqual(<<"/~01">>, valid_json_location:pointer([<<"~1">>])),
     ?_assertEqual(<<"/~0">>, valid_json_location:pointer([<<"~">>])),
     ?_assertEqual(<<"/~1">>, valid_json_location:pointer([<<"/">>])),
     ?_assertEqual(<<"/~1~1">>, valid_json_location:pointer([<<"//">>])),
     %% Percent-encoding в JSON Pointer не делается.
     ?_assertEqual(<<"/a b%">>, valid_json_location:pointer([<<"a b%">>]))].

%% Разбор указателя обратен печати, поэтому проверяется через круг: адрес node
%% хранит готовый указатель, а обходу нужен стек сегментов.
segments_test_() ->
    Stacks = [[],
              [<<"type">>],
              [<<"type">>, <<"a">>, <<"properties">>],
              [<<>>],
              [<<"a">>, <<>>],
              [<<"~a/b">>],
              %% "~01" — экранированное "~1", а не косая черта.
              [<<"~1">>],
              [<<"/">>, <<"~">>]],
    [{binary_to_list(valid_json_location:pointer(Stack)),
      ?_assertEqual(Stack, valid_json_location:segments(valid_json_location:pointer(Stack)))}
     || Stack <- Stacks].

%% Fragment строится поверх того же указателя: сначала pointer escaping, затем
%% percent-encoding символов, недопустимых во fragment.
fragment_test_() ->
    Uri = <<"https://example.com/s">>,
    [?_assertEqual(<<"https://example.com/s#">>,
                   valid_json_location:fragment({Uri, []})),
     ?_assertEqual(<<"https://example.com/s#/properties/~0a~1b/type">>,
                   valid_json_location:fragment({Uri, [<<"type">>, <<"~a/b">>,
                                                       <<"properties">>]})),
     %% "~" остаётся буквальным: он входит в unreserved.
     ?_assertEqual(<<"https://example.com/s#/~0">>,
                   valid_json_location:fragment({Uri, [<<"~">>]})),
     ?_assertEqual(<<"https://example.com/s#/a%20b">>,
                   valid_json_location:fragment({Uri, [<<"a b">>]})),
     ?_assertEqual(<<"https://example.com/s#/%22%23%25">>,
                   valid_json_location:fragment({Uri, [<<"\"#%">>]})),
     %% Sub-delims и ":" во fragment допустимы и не кодируются.
     ?_assertEqual(<<"https://example.com/s#/a!$&'()*+,;=:@">>,
                   valid_json_location:fragment({Uri, [<<"a!$&'()*+,;=:@">>]})),
     %% Не-ASCII кодируется побайтово в UTF-8.
     ?_assertEqual(<<"https://example.com/s#/%D1%84">>,
                   valid_json_location:fragment({Uri, [<<"ф"/utf8>>]}))].

%% Проекция получает готовый compiled pointer и дописывает максимум один raw
%% keyword segment. Результат обязан совпадать с общим путём через стек.
compiled_fragment_test_() ->
    Uri = <<"https://example.com/s">>,
    Cases = [{[], none},
             {[<<"~a/b">>, <<"properties">>], none},
             {[], <<>>},
             {[<<"~a/b">>, <<"properties">>], <<"type">>},
             {[<<"base">>], <<"~1 /%#">>},
             {[<<"base">>], <<"ф"/utf8>>}],
    [?_assertEqual(valid_json_location:fragment({Uri, tail(Tail, Stack)}),
                   valid_json_location:fragment(
                     {Uri, valid_json_location:pointer(Stack)}, Tail))
     || {Stack, Tail} <- Cases].

tail(none, Stack) -> Stack;
tail(Segment, Stack) -> [Segment | Stack].
