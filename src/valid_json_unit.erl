%% Построение output units из контекста вычисления. Локации остаются адресом
%% schema node и обратными стеками: печать и escaping выполняются при проекции.
-module(valid_json_unit).

-include("valid_json_core.hrl").

-export([keyword/4, keyword/5, keyword_units/5, reference/5, schema/4]).

%% Unit фактически написанного keyword стоит на сегмент глубже своего node.
%% Составной constraint выпускает по одному unit на каждый фактический keyword,
%% поэтому имя передаётся, а не выводится из тега IR. Детей у keyword нет, пока
%% он не applicator.
-spec keyword(binary(), boolean(), detail(), #eval_context{}) -> #output_unit{}.
keyword(Keyword, Valid, Detail, Context) ->
    keyword(Keyword, Valid, Detail, [], Context).

%% Applicator кладёт units применённых nodes внутрь собственного unit: уровни
%% дерева чередуются (validator-core.md, «Output unit и локации»).
-spec keyword(binary(), boolean(), detail(), [#output_unit{}], #eval_context{}) ->
          #output_unit{}.
keyword(Keyword, Valid, Detail, Nested, #eval_context{keyword_location = Location} = Context) ->
    build(keyword, Valid, [Keyword | Location], Detail, Nested, Context).

%% Applicator в режиме flag units не собирает вовсе: ответ исчерпывается
%% вердиктом (validator-core.md, «Проекции output»).
-spec keyword_units(binary(), boolean(), detail(), [#output_unit{}], #eval_context{}) ->
          [#output_unit{}].
keyword_units(_Keyword, _Valid, _Detail, _Nested, #eval_context{format = flag}) ->
    [];
keyword_units(_Keyword, _Valid, none, Nested, #eval_context{format = basic}) ->
    Nested;
keyword_units(Keyword, Valid, Detail, Nested,
              #eval_context{format = basic} = Context) ->
    [keyword(Keyword, Valid, Detail, [], Context) | Nested];
keyword_units(Keyword, Valid, Detail, Nested, Context) ->
    [keyword(Keyword, Valid, Detail, Nested, Context)].

%% Reference хранит два уровня. Собственный unit называет написанный keyword и
%% его physical absolute location; вложенный schema unit уже называет
%% каноническую target schema. Так эти уровни показаны в normative verbose
%% example, и проекция может не смешивать source с dereferenced target.
-spec reference(binary(), addr(), boolean(), [#output_unit{}], #eval_context{}) ->
          #output_unit{}.
reference(Keyword, _Addr, Valid, Nested,
          #eval_context{keyword_location = Location} = Context) ->
    build(keyword, Valid, [Keyword | Location], none, Nested, Context).

%% Unit самого node: своего сегмента у него нет, он стоит там же, где схема, и
%% держит внутри units своих keywords.
-spec schema(boolean(), detail(), [#output_unit{}], #eval_context{}) -> #output_unit{}.
schema(Valid, Detail, Nested, #eval_context{keyword_location = Location} = Context) ->
    build(schema, Valid, Location, Detail, Nested, Context).

%% Адрес node сохраняется без разбора compiled pointer. Проекция материализует
%% absoluteKeywordLocation только для оставшихся после фильтрации units; у
%% keyword его собственное имя уже лежит в голове keyword_location.
-spec build(unit_kind(), boolean(), [binary()], detail(), [#output_unit{}],
            #eval_context{}) -> #output_unit{}.
build(Kind, Valid, Location, Detail, Nested,
      #eval_context{node = Node, instance_location = {_Depth, Instance}}) ->
    #output_unit{kind              = Kind,
                 valid             = Valid,
                 schema_location   = Node,
                 keyword_location  = Location,
                 instance_location = Instance,
                 detail            = Detail,
                 nested            = Nested}.
