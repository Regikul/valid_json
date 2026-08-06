%% Единая точка доступа к URI API. На OTP 20 parse/recompose/normalize
%% приходят из вендоренного uri_string, а на OTP 21 — из stdlib. Resolve на
%% OTP 21 реализован здесь, потому что в системном модуле этой функции ещё нет.
-module(valid_json_uri_backend).

-export([parse/1, recompose/1, normalize/1, resolve/2]).
-export_type([uri_map/0]).

-type uri_map() :: map().

-ifdef(CAP_URI_RESOLVE).

parse(Uri) ->
    uri_string:parse(Uri).

recompose(UriMap) ->
    uri_string:recompose(UriMap).

normalize(Uri) ->
    uri_string:normalize(Uri).

resolve(Reference, Base) ->
    uri_string:resolve(Reference, Base).

-else.

parse(Uri) ->
    uri_string:parse(Uri).

recompose(UriMap) ->
    uri_string:recompose(UriMap).

normalize(Uri) ->
    uri_string:normalize(Uri).

resolve(Reference, Base) ->
    resolve_legacy(Reference, Base).

-endif.

-ifndef(CAP_URI_RESOLVE).

%% Публичный resolve/2 появился в OTP 22. Эта ветка повторяет RFC 3986,
%% раздел 5.2, для binary URI, которые передаёт valid_json_uri.
resolve_legacy(Reference, Base) ->
    case uri_string:parse(Reference) of
        RefMap when is_map(RefMap) ->
            resolve_legacy_map(RefMap, Base);
        Error ->
            Error
    end.

resolve_legacy_map(RefMap, Base) ->
    case uri_string:parse(Base) of
        BaseMap when is_map(BaseMap) ->
            resolve_map(RefMap, BaseMap);
        Error ->
            Error
    end.

resolve_map(#{scheme := _} = RefMap, _BaseMap) ->
    recompose(normalize_path(RefMap));
resolve_map(RefMap, #{scheme := Scheme} = BaseMap) ->
    case path_kind(RefMap) of
        host ->
            recompose(normalize_path(RefMap#{scheme => Scheme}));
        empty ->
            Keys = case maps:is_key(query, RefMap) of
                       true  -> [scheme, userinfo, host, port, path];
                       false -> [scheme, userinfo, host, port, path, query]
                   end,
            recompose(maps:merge(RefMap, maps:with(Keys, BaseMap)));
        absolute ->
            recompose(normalize_path(
                        maps:merge(RefMap,
                                   maps:with([scheme, userinfo, host, port],
                                             BaseMap))));
        relative ->
            Path = merge_paths(maps:get(path, RefMap, <<>>), BaseMap),
            recompose(normalize_path(
                        maps:merge(RefMap#{path => Path},
                                   maps:with([scheme, userinfo, host, port],
                                             BaseMap))))
    end;
resolve_map(_RefMap, _BaseMap) ->
    {error, invalid_scheme, ""}.

path_kind(RefMap) ->
    case maps:is_key(host, RefMap) of
        true -> host;
        false ->
            case iolist_to_binary(maps:get(path, RefMap, <<>>)) of
                <<>>       -> empty;
                <<$/, _/bits>> -> absolute;
                _          -> relative
            end
    end.

merge_paths(Path, BaseMap) ->
    BasePath = iolist_to_binary(maps:get(path, BaseMap, <<>>)),
    case {maps:is_key(host, BaseMap), BasePath} of
        {true, <<>>} -> <<$/, Path/binary>>;
        _ ->
            case string:split(BasePath, <<$/>>, trailing) of
                [Prefix, _] -> <<Prefix/binary, $/, Path/binary>>;
                [_]         -> Path
            end
    end.

normalize_path(Map) ->
    Path = iolist_to_binary(maps:get(path, Map, <<>>)),
    Map#{path => remove_dot_segments(Path)}.

remove_dot_segments(Path) ->
    remove_dot_segments(Path, <<>>).

remove_dot_segments(<<>>, Output) ->
    Output;
remove_dot_segments(<<"../", Tail/binary>>, Output) ->
    remove_dot_segments(Tail, Output);
remove_dot_segments(<<"./", Tail/binary>>, Output) ->
    remove_dot_segments(Tail, Output);
remove_dot_segments(<<"/./", Tail/binary>>, Output) ->
    remove_dot_segments(<<$/, Tail/binary>>, Output);
remove_dot_segments(<<"/.">>, Output) ->
    remove_dot_segments(<<$/>>, Output);
remove_dot_segments(<<"/../", Tail/binary>>, Output) ->
    remove_dot_segments(<<$/, Tail/binary>>, remove_last_segment(Output));
remove_dot_segments(<<"/..">>, Output) ->
    remove_dot_segments(<<$/>>, remove_last_segment(Output));
remove_dot_segments(<<".">>, Output) ->
    remove_dot_segments(<<>>, Output);
remove_dot_segments(<<"..">>, Output) ->
    remove_dot_segments(<<>>, Output);
remove_dot_segments(Input, Output) ->
    {First, Rest} = first_path_segment(Input),
    remove_dot_segments(Rest, <<Output/binary, First/binary>>).

first_path_segment(Input) ->
    first_path_segment(Input, <<>>).

first_path_segment(<<$/, Tail/binary>>, Acc) ->
    first_path_segment_end(Tail, <<Acc/binary, $/>>);
first_path_segment(<<Char, Tail/binary>>, Acc) ->
    first_path_segment_end(Tail, <<Acc/binary, Char>>).

first_path_segment_end(<<>>, Acc) ->
    {Acc, <<>>};
first_path_segment_end(<<$/, _/binary>> = Rest, Acc) ->
    {Acc, Rest};
first_path_segment_end(<<Char, Tail/binary>>, Acc) ->
    first_path_segment_end(Tail, <<Acc/binary, Char>>).

remove_last_segment(<<>>) ->
    <<>>;
remove_last_segment(Binary) ->
    case binary:matches(Binary, <<"/">>) of
        [] ->
            <<>>;
        Matches ->
            {Position, _Length} = lists:last(Matches),
            binary:part(Binary, 0, Position)
    end.

-endif.
