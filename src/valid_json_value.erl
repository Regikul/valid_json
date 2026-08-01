%% Модель JSON-значения: предикаты типов над термами json:decode/1.
%% Нормативное описание — okf/architecture/validator-core.md, раздел
%% «Модель JSON-значения».
-module(valid_json_value).

-include("valid_json_core.hrl").

-export([is_type/2]).

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
