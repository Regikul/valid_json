%% Проекции дерева units в standard output formats.
%% Все структурные форматы строятся из одного дерева; см. validator-core.md.
-module(valid_json_output).

-include("valid_json_core.hrl").

-export([project/2]).

-spec project(format(), #eval_result{}) -> output().
project(flag, #eval_result{valid = Valid}) ->
    #{<<"valid">> => Valid};
project(basic, #eval_result{units = [Root]}) ->
    basic(Root);
project(detailed, #eval_result{units = [Root]}) ->
    detailed(Root);
project(verbose, #eval_result{units = [Root]}) ->
    verbose(Root).

%% basic — корневой unit, внутри которого плоский список потомков: при провале
%% сообщения об ошибках, при успехе аннотации. Ключ соответствует валидности
%% корня и присутствует всегда, хотя бы пустым; второго ключа рядом быть не
%% должно (validator-core.md, «Проекции output»).
-spec basic(#output_unit{}) -> output().
basic(#output_unit{valid = Valid} = Root) ->
    (unit(Root))#{key(Valid) => [unit(Unit) || Unit <- flatten(Valid, Root)]}.

key(false) -> <<"errors">>;
key(true)  -> <<"annotations">>.

%% Потомки в порядке обхода: своё дерево unit уже потерял, поэтому вложенность
%% в плоском списке не печатается.
-spec flatten(boolean(), #output_unit{}) -> [#output_unit{}].
flatten(Valid, #output_unit{nested = Nested}) ->
    lists:append([[Unit || carries(Valid, Unit)] ++ descend(Valid, Unit) || Unit <- Nested]).

%% Провалившийся schema object не производит аннотаций ни своими keywords, ни
%% keywords своих подсхем (core.txt:1206), поэтому обход в него не спускается.
%% Из дерева аннотации не исчезают: их показывает verbose. При провале корня
%% обходится всё — units успешных ветвей остаются диагностическими.
-spec descend(boolean(), #output_unit{}) -> [#output_unit{}].
descend(true, #output_unit{valid = false}) -> [];
descend(Valid, Unit)                       -> flatten(Valid, Unit).

%% В список попадает то, что несёт detail. Unit без него из дерева не исчезает:
%% его показывает verbose. Ветвление своего сообщения не имеет и потому в
%% плоском списке не видно, а провалившаяся boolean-схема видна: сообщение есть
%% только у неё самой.
-spec carries(boolean(), #output_unit{}) -> boolean().
carries(false, #output_unit{detail = {error, _}})     -> true;
carries(true, #output_unit{detail = {annotation, _}}) -> true;
carries(_Valid, #output_unit{})                       -> false.

%% detailed выбирает из diagnostic tree только ошибки провалившегося корня
%% либо effective annotations успешного. Затем применяются нормативные правила:
%% пустой silent unit удаляется, unit с одним значимым потомком заменяется этим
%% потомком, а развилка остаётся branch node без обязательного local detail.
-spec detailed(#output_unit{}) -> output().
detailed(#output_unit{valid = Valid} = Root) ->
    Kept = kept_detail(Valid),
    Nested = prune_children(Kept, Root),
    Detail = selected_detail(Kept, Root#output_unit.detail, Nested),
    tree(Root#output_unit{detail = Detail, nested = Nested}).

-spec kept_detail(boolean()) -> error | annotation.
kept_detail(false) -> error;
kept_detail(true)  -> annotation.

-spec prune_children(error | annotation, #output_unit{}) -> [#output_unit{}].
prune_children(Kept, #output_unit{nested = Nested}) ->
    lists:append([prune(Kept, Unit) || Unit <- Nested]).

%% Detailed сохраняет только ветви, чей verdict совпадает с корнем. Поэтому
%% failed branch успешного applicator'а не выглядит ошибкой общего результата,
%% а successful branch провалившегося applicator'а не раздувает errors.
-spec prune(error | annotation, #output_unit{}) -> [#output_unit{}].
prune(error, #output_unit{valid = true}) ->
    [];
prune(annotation, #output_unit{valid = false}) ->
    [];
prune(Kept, Unit) ->
    Nested = prune_children(Kept, Unit),
    Detail = selected_detail(Kept, Unit#output_unit.detail, Nested),
    compact(Unit#output_unit{detail = Detail, nested = Nested}).

%% Error applicator'а — общий итог ветвления. Когда дочерние причины уже есть,
%% branch не повторяет generic message; если после фильтрации детей нет (`not`),
%% собственная ошибка остаётся leaf. Annotation является самостоятельным
%% результатом keyword и сохраняется рядом с nested annotations.
-spec selected_detail(error | annotation, detail(), [#output_unit{}]) -> detail().
selected_detail(error, {error, _} = Detail, []) -> Detail;
selected_detail(annotation, {annotation, _} = Detail, _Nested) -> Detail;
selected_detail(_Kept, _Detail, _Nested) -> none.

-spec compact(#output_unit{}) -> [#output_unit{}].
compact(#output_unit{detail = none, nested = []}) ->
    [];
compact(#output_unit{detail = none, nested = [Only]}) ->
    [Only];
compact(Unit) ->
    [Unit].

%% В отличие от verbose, detailed tree уже полностью отфильтровано и сжато:
%% renderer не применяет к нему дополнительных правил видимости.
-spec tree(#output_unit{}) -> output().
tree(#output_unit{nested = []} = Unit) ->
    unit(Unit);
tree(#output_unit{valid = Valid, nested = Nested} = Unit) ->
    (unit(Unit))#{key(Valid) => [tree(Child) || Child <- Nested]}.

%% verbose сохраняет все keyword results и значимые границы подсхем. Schema
%% unit, стоящий на той же позиции, что применивший его keyword, является
%% внутренним контейнером evaluator и прозрачен. Границы именованных branches
%% (`anyOf/0`, `properties/name`, ...), target schema после reference и
%% boolean-failure остаются самостоятельными output units.
-spec verbose(#output_unit{}) -> output().
verbose(Root) ->
    hierarchy(Root).

-spec hierarchy(#output_unit{}) -> output().
hierarchy(#output_unit{valid = Valid} = Unit) ->
    case children(Unit) of
        []     -> unit(Unit);
        Nested -> (unit(Unit))#{key(Valid) => Nested}
    end.

-spec children(#output_unit{}) -> [output()].
children(#output_unit{nested = Nested} = Parent) ->
    lists:append([visible(Parent, Unit) || Unit <- Nested]).

%% Target schema даже без keywords важна: её canonical location отличает
%% написанную reference от применённого ресурса. Для остальных applicators
%% пустая успешная schema результата не добавляет — так ведёт себя normative
%% пример с `properties: {"validProp": true}`.
-spec visible(#output_unit{}, #output_unit{}) -> [output()].
visible(Parent, #output_unit{kind = schema} = Unit) ->
    case reference(Parent) of
        true ->
            [hierarchy(Unit)];
        false ->
            visible_schema(Parent, Unit)
    end;
visible(_Parent, #output_unit{kind = keyword} = Unit) ->
    [hierarchy(Unit)].

-spec visible_schema(#output_unit{}, #output_unit{}) -> [output()].
visible_schema(_Parent, #output_unit{detail = none, nested = []}) ->
    [];
visible_schema(#output_unit{keyword_location = Location},
               #output_unit{keyword_location = Location, detail = none} = Unit) ->
    children(Unit);
visible_schema(_Parent, Unit) ->
    [hierarchy(Unit)].

-spec reference(#output_unit{}) -> boolean().
reference(#output_unit{kind = keyword,
                       keyword_location = [Keyword | _]}) ->
    lists:member(Keyword, [<<"$ref">>, <<"$dynamicRef">>, <<"$recursiveRef">>]);
reference(#output_unit{}) ->
    false.

-spec unit(#output_unit{}) -> output().
unit(#output_unit{valid = Valid, keyword_location = Keywords,
                  absolute_location = Absolute, instance_location = Instance,
                  detail = Detail}) ->
    Unit = #{<<"valid">>            => Valid,
             <<"keywordLocation">>  => valid_json_location:pointer(Keywords),
             <<"instanceLocation">> => valid_json_location:pointer(Instance)},
    detail(Detail, absolute(Absolute, Unit)).

%% Анонимный resource URI не синтезирует, поэтому ключ просто отсутствует.
-spec absolute({uri(), [binary()]} | undefined, output()) -> output().
absolute(undefined, Unit) ->
    Unit;
absolute(Location, Unit) ->
    Unit#{<<"absoluteKeywordLocation">> => valid_json_location:fragment(Location)}.

-spec detail(detail(), output()) -> output().
detail({error, Message}, Unit)    -> Unit#{<<"error">> => Message};
detail({annotation, Value}, Unit) -> Unit#{<<"annotation">> => Value};
detail(none, Unit)                -> Unit.
