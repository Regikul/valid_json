%% Построение output units из контекста вычисления. Локации остаются обратными
%% стеками: печать и escaping делает valid_json_location при проекции.
-module(valid_json_unit).

-include("valid_json_core.hrl").

-export([keyword/4, keyword/5, reference/5, schema/4]).

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
    build(keyword, Valid, [Keyword | Location], [Keyword], Detail, Nested, Context).

%% Reference хранит два уровня. Собственный unit называет написанный keyword и
%% его physical absolute location; вложенный schema unit уже называет
%% каноническую target schema. Так эти уровни показаны в normative verbose
%% example, и проекция может не смешивать source с dereferenced target.
-spec reference(binary(), addr(), boolean(), [#output_unit{}], #eval_context{}) ->
          #output_unit{}.
reference(Keyword, _Addr, Valid, Nested,
          #eval_context{keyword_location = Location} = Context) ->
    build(keyword, Valid, [Keyword | Location], [Keyword], none, Nested, Context).

%% Unit самого node: своего сегмента у него нет, он стоит там же, где схема, и
%% держит внутри units своих keywords.
-spec schema(boolean(), detail(), [#output_unit{}], #eval_context{}) -> #output_unit{}.
schema(Valid, Detail, Nested, #eval_context{keyword_location = Location} = Context) ->
    build(schema, Valid, Location, [], Detail, Nested, Context).

%% keyword location накапливается обходом, абсолютная выводится из адреса node:
%% путь внутри resource уже лежит в pointer, и к нему дописывается имя keyword.
-spec build(unit_kind(), boolean(), [binary()], [binary()], detail(), [#output_unit{}],
            #eval_context{}) -> #output_unit{}.
build(Kind, Valid, Location, Tail, Detail, Nested,
      #eval_context{instance_location = {_Depth, Instance}} = Context) ->
    #output_unit{kind              = Kind,
                 valid             = Valid,
                 keyword_location  = Location,
                 absolute_location = absolute(Tail, Context),
                 instance_location = Instance,
                 detail            = Detail,
                 nested            = Nested}.

%% Анонимный resource URI не имеет, поэтому и абсолютной локации у него нет
%% (validator-core.md, «Представление скомпилированной схемы»).
-spec absolute([binary()], #eval_context{}) -> {uri(), [binary()]} | undefined.
absolute(Tail, #eval_context{node = {Rid, Pointer}, schema = #{resources := Resources}}) ->
    case maps:get(Rid, Resources) of
        #resource{id = undefined} -> undefined;
        #resource{id = Uri}       -> {Uri, Tail ++ valid_json_location:segments(Pointer)}
    end.
