%% Чистый реестр JSON Schema documents. Он держит документ под двумя именами —
%% именем регистрации и каноническим, — но ничего не компилирует и не знает о
%% ссылках. Адресом схемы служит каноническое имя; имя регистрации нужно
%% компиляции, чтобы разрешать `$ref`, написанные относительно него.
%% Нормативный контракт — okf/architecture/validator-resources-runtime.md,
%% разделы «Registry без сети» и «API и фазы компиляции».
%%
%% Регистрация состоит из двух ступеней, и `add/2` — вторая: она принимает
%% только пары «имя — документ». Первая ступень, `name_entries/2`, нужна тем,
%% кто имени не принёс: она выводит его из `$id` самой схемы. Так у каждой
%% ступени одна форма входа, и разбирать, что именно ей дали, не приходится.
-module(valid_json_store).

-include("valid_json_resources.hrl").

-export([new/1, temporary/0, name_entries/2, add/2, add/3, remove/2, fetch/2,
         canonical_names/1, base/1, resolve_name/2, from_documents/2]).
-export_type([store/0, registry_option/0]).

%% Реестр называет свои документы, поэтому `base_uri` ему обязателен: без него
%% имя регистрации осталось бы относительным, а адреса у схемы не возникло бы.
%% `new/1` не имеет error-ветви по публичному контракту: отсутствующая или
%% ошибочная опция — ошибка вызова API, поэтому она завершается badarg, а не
%% schema_error.
-spec new([registry_option()]) -> store().
new(Options) when is_list(Options) ->
    case base_option(Options) of
        {ok, Base} -> #store{base = Base};
        error      -> erlang:error(badarg, [Options])
    end;
new(Options) ->
    erlang:error(badarg, [Options]).

%% Реестр на один вызов компиляции: схема пришла значением, регистрировать её
%% негде и называть нечем, а нужен он затем, чтобы достать встроенные метасхемы.
%% Имён этот реестр не разрешает и потому обходится без `base_uri`.
-spec temporary() -> store().
temporary() ->
    #store{}.

%% Первая ступень регистрации: схема, пришедшая без имени, называет себя сама.
%% Имя выводится из `$id` и разрешается от базы хранилища — это четвёртый слой
%% лестницы баз RFC 3986, application-dependent default, на который спека
%% ссылается прямо (core.txt:1811). Не назвавшая себя схема дальше не идёт:
%% корень документа всегда является schema resource и обязан иметь абсолютное
%% имя (core.txt:565). Так же отвергается boolean — keywords он не несёт, и
%% `$id` в нём быть не может.
%%
%% Ошибка называется `anonymous`: написания, с каким пришёл вызывающий, у такой
%% записи нет. Собираются они все, как и на второй ступени, но с ней в один
%% список не сходятся: пока имя не выведено, регистрировать нечего, и до разбора
%% путей дело не доходит.
-spec name_entries(store(), [json()]) ->
          {ok, [{uri(), json()}]} | {error, [{anonymous, #schema_error{}}]}.
name_entries(#store{} = Store, Entries) when is_list(Entries) ->
    case lists:foldl(fun(Entry, Acc) -> name_entry(Entry, Store#store.base, Acc) end,
                     {[], []}, Entries) of
        {Named, []}      -> {ok, lists:reverse(Named)};
        {_Named, Errors} -> {error, lists:reverse(Errors)}
    end;
name_entries(Store, Entries) ->
    erlang:error(badarg, [Store, Entries]).

%% Схема — это объект либо boolean, и других форм здесь нет: пара сюда не ходит
%% вовсе, а падение на ней `function_clause` называет и функцию, и сам негодный
%% элемент.
-spec name_entry(json(), rid(),
                 {[{uri(), json()}], [{anonymous, #schema_error{}}]}) ->
          {[{uri(), json()}], [{anonymous, #schema_error{}}]}.
name_entry(Json, Base, {Named, Errors}) when is_map(Json); is_boolean(Json) ->
    case name_of(Json, Base) of
        {ok, Name}     -> {[{Name, Json} | Named], Errors};
        {error, Error} -> {Named, [{anonymous, Error} | Errors]}
    end.

%% Разрешение `$id` то же самое, каким пользуется вторая ступень: правило имени
%% в реестре одно. Boolean сюда попадает второй клаузой — `$id` в нём нет и быть
%% не может.
-spec name_of(json(), rid()) -> {ok, uri()} | {error, #schema_error{}}.
name_of(#{<<"$id">> := _} = Json, Base) ->
    canonical(Json, Base);
name_of(_Json, _Base) ->
    schema_error(unnamed_schema).

%% Запись здесь одна, поэтому имя ошибки вызывающий знает и без нас.
-spec add(store(), uri(), json()) ->
          {ok, uri(), store()} | {error, #schema_error{}}.
add(Store, Uri, Json) ->
    case add(Store, [{Uri, Json}]) of
        {ok, [Canonical], Added} -> {ok, Canonical, Added};
        {error, [{Uri, Error}]}  -> {error, Error}
    end.

%% Списочная регистрация атомарна относительно значения: сначала строятся все
%% documents и снимаются заменяемые записи, затем проверяются конфликты. Ошибка
%% не возвращает промежуточный store вызывающему.
%%
%% Ошибки собираются все: записи разбираются независимо, и показать разом весь
%% испорченный вызов полезнее, чем первую попавшуюся запись. Имя ошибки — то
%% написание, с каким пришёл вызывающий: канонического имени у отвергнутой
%% записи может не быть вовсе, а `name_taken` называет чужое.
%%
%% Фазы не смешиваются: пока хоть одно имя не разрешилось, конфликты не
%% считаются — считать их не из чего, документов нет.
-spec add(store(), [{uri(), json()}]) ->
          {ok, [uri()], store()} | {error, [{uri(), #schema_error{}}]}.
add(#store{} = Store, Entries) when is_list(Entries) ->
    case documents(Entries, Store#store.base) of
        {ok, Added} -> insert_all(Added, Store);
        {error, _} = Error -> Error
    end;
add(Store, Entries) ->
    erlang:error(badarg, [Store, Entries]).

%% Снятый документ называется парой: написанием вызывающего и своим каноническим
%% именем. Первое нужно тому, кто станет называть им ошибку, второе — тому, кто
%% держит артефакты. Запись, не нашедшая документа, пары не даёт и ошибкой не
%% считается: удалять нечего. Ошибки разрешения имён собираются все, как в
%% `add/2`, и по той же причине.
-spec remove(store(), [uri()]) ->
          {ok, [{uri(), uri()}], store()} | {error, [{uri(), #schema_error{}}]}.
remove(#store{} = Store, Uris) when is_list(Uris) ->
    case names(Uris, Store#store.base) of
        {ok, Names} ->
            {Removed, Documents} = remove_names(Names, Store#store.documents),
            {ok, Removed, Store#store{documents = Documents}};
        {error, _} = Error ->
            Error
    end;
remove(Store, Uris) ->
    erlang:error(badarg, [Store, Uris]).

%% Compiler передаёт сюда уже разрешённое каноническое имя. Пользовательский
%% registry имеет приоритет; промах читается из отдельной immutable области.
-spec fetch(uri(), store()) -> #document{} | undefined.
fetch(Uri, #store{documents = Documents}) ->
    case maps:get(Uri, Documents, undefined) of
        undefined -> fetch_builtin(Uri);
        Document  -> Document
    end.

%% Оба ключа документа дают одно каноническое имя, поэтому список без повторов.
%% Встроенная область сюда не попадает: её документы в реестре не лежат.
-spec canonical_names(store()) -> [uri()].
canonical_names(#store{documents = Documents}) ->
    ordsets:from_list([Canonical
                       || #document{canonical = Canonical}
                              <- maps:values(Documents)]).

%% База нужна снаружи одному читателю артефактов: он разрешает от неё короткое
%% имя тем же правилом, каким разрешается регистрируемое. Отдаётся она уже
%% нормализованной, то есть ровно такой, какой пользуется сам реестр.
-spec base(store()) -> uri() | anonymous.
base(#store{base = Base}) ->
    Base.

%% Правило разрешения имени публично затем, чтобы регистрация и валидация не
%% разошлись: обе зовут одно и то же.
-spec resolve_name(uri(), rid()) -> {ok, uri()} | {error, #schema_error{}}.
resolve_name(Uri, Base) ->
    registration_name(Uri, Base).

%% Обратная сборка реестра из документов: двухключевое устройство остаётся
%% внутри модуля, а снаружи документ переносится как одно целое. Оба ключа
%% восстанавливаются из полей самого документа, поэтому список повторов не
%% содержит.
-spec from_documents([#document{}], [registry_option()]) -> store().
from_documents(Documents, Options) when is_list(Documents) ->
    Store = new(Options),
    Store#store{documents = index(Documents)}.

-spec index([#document{}]) -> #{uri() => #document{}}.
index(Documents) ->
    lists:foldl(fun(#document{registered = Registered,
                              canonical = Canonical} = Document, Acc) ->
                        Acc#{Registered => Document, Canonical => Document}
                end, #{}, Documents).

-spec base_option([term()]) -> {ok, uri()} | error.
base_option([{base_uri, Uri}]) when is_binary(Uri) ->
    hierarchical_base(Uri);
base_option(_Options) ->
    error.

%% Относительные имена безопасно разрешаются только от hierarchical URI.
%% Authority делает URI hierarchical независимо от path; без authority path
%% обязан быть абсолютным. Так `file:/schemas/root` разрешён, а URN отвергнут.
%% Query у base_uri запрещён: разрешение относительного имени его всё равно
%% отбрасывает, а завершающий слэш дописывать было бы некуда.
-spec hierarchical_base(uri()) -> {ok, uri()} | error.
hierarchical_base(Uri) ->
    case {valid_json_uri_backend:parse(Uri),
          valid_json_uri:resolve(Uri, anonymous)} of
        {#{query := _}, _} ->
            error;
        {#{scheme := _, host := _}, {ok, Normalized, root}} ->
            {ok, trailing_slash(Normalized)};
        {#{scheme := _, path := <<"/", _/binary>>}, {ok, Normalized, root}} ->
            {ok, trailing_slash(Normalized)};
        _ ->
            error
    end.

%% Завершающий слэш дописывается как нормализация: без него разрешение съело бы
%% последний сегмент, и `product/banana` под `https://shop.service/schemas`
%% попало бы в `https://shop.service/product/banana`.
-spec trailing_slash(uri()) -> uri().
trailing_slash(Uri) ->
    case binary:last(Uri) of
        $/    -> Uri;
        _Byte -> <<Uri/binary, "/">>
    end.

%% Записи разбираются независимо друг от друга, поэтому ошибки одной не мешают
%% увидеть ошибки остальных. Документ сохраняется вместе с именем записи: под
%% ним же называется ошибка следующей фазы.
-spec documents([term()], rid()) ->
          {ok, [{uri(), #document{}}]} | {error, [{uri(), #schema_error{}}]}.
documents(Entries, Base) ->
    case lists:foldl(fun(Entry, Acc) -> build(Entry, Base, Acc) end,
                     {[], []}, Entries) of
        {Documents, []} -> {ok, lists:reverse(Documents)};
        {_Documents, Errors} -> {error, lists:reverse(Errors)}
    end.

-spec build(term(), rid(), {[{uri(), #document{}}], [{uri(), #schema_error{}}]}) ->
          {[{uri(), #document{}}], [{uri(), #schema_error{}}]}.
build({Uri, Json}, Base, {Documents, Errors}) when is_binary(Uri) ->
    case document(Uri, Json, Base) of
        {ok, Document}     -> {[{Uri, Document} | Documents], Errors};
        {error, Error}     -> {Documents, [{Uri, Error} | Errors]}
    end;
build(_Entry, _Base, _Acc) ->
    erlang:error(badarg).

-spec document(uri(), json(), rid()) -> {ok, #document{}} | {error, #schema_error{}}.
document(Uri, Json, Base) ->
    case registration_name(Uri, Base) of
        {ok, Registered} ->
            case canonical(Json, Registered) of
                {ok, Canonical} ->
                    {ok, #document{registered = Registered,
                                   canonical = Canonical,
                                   json = Json}};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec registration_name(uri(), rid()) -> {ok, uri()} | {error, #schema_error{}}.
registration_name(Uri, Base) ->
    case valid_json_uri:resolve(Uri, Base) of
        {ok, Name, root} when Name =/= anonymous -> {ok, Name};
        {ok, _Name, _Fragment}                  -> schema_error(invalid_uri);
        {error, Reason}                         -> schema_error(Reason)
    end.

-spec canonical(json(), rid()) -> {ok, uri()} | {error, #schema_error{}}.
canonical(#{<<"$id">> := Id}, Registered) when is_binary(Id) ->
    case valid_json_uri:resolve(Id, Registered) of
        {ok, Canonical, root} when Canonical =/= anonymous -> {ok, Canonical};
        {ok, _Canonical, _Fragment} -> schema_error({bad_keyword_value, Id});
        {error, Reason}             -> schema_error(Reason)
    end;
canonical(#{<<"$id">> := Id}, _Registered) ->
    schema_error({bad_keyword_value, Id});
canonical(_Json, Registered) ->
    {ok, Registered}.

-spec names([term()], rid()) ->
          {ok, [{uri(), uri()}]} | {error, [{uri(), #schema_error{}}]}.
names(Uris, Base) ->
    case lists:foldl(fun(Uri, Acc) -> name(Uri, Base, Acc) end, {[], []}, Uris) of
        {Names, []} -> {ok, lists:reverse(Names)};
        {_Names, Errors} -> {error, lists:reverse(Errors)}
    end.

-spec name(term(), rid(), {[{uri(), uri()}], [{uri(), #schema_error{}}]}) ->
          {[{uri(), uri()}], [{uri(), #schema_error{}}]}.
name(Uri, Base, {Names, Errors}) when is_binary(Uri) ->
    case registration_name(Uri, Base) of
        {ok, Name}     -> {[{Uri, Name} | Names], Errors};
        {error, Error} -> {Names, [{Uri, Error} | Errors]}
    end;
name(_Uri, _Base, _Acc) ->
    erlang:error(badarg).

-spec insert_all([{uri(), #document{}}], store()) ->
          {ok, [uri()], store()} | {error, [{uri(), #schema_error{}}]}.
insert_all(Added, #store{documents = Existing} = Store) ->
    Registrations = [Uri || {_Entry, #document{registered = Uri}} <- Added],
    Stripped = strip_replacements(Registrations, Existing),
    case lists:foldl(fun insert/2, {[], [], Stripped}, Added) of
        {Canonicals, [], Documents} ->
            {ok, lists:reverse(Canonicals), Store#store{documents = Documents}};
        {_Canonicals, Errors, _Documents} ->
            {error, lists:reverse(Errors)}
    end.

%% Отвергнутая запись не вставляется, а обход продолжается: так за один вызов
%% видно все конфликты. Невидимым остаётся один — конфликт с записью, которая и
%% сама отвергнута, потому что в реестр она не попала.
-spec insert({uri(), #document{}},
             {[uri()], [{uri(), #schema_error{}}], #{uri() => #document{}}}) ->
          {[uri()], [{uri(), #schema_error{}}], #{uri() => #document{}}}.
insert({Entry, #document{registered = Registered, canonical = Canonical} = Document},
       {Canonicals, Errors, Documents0}) ->
    %% Повтор имени регистрации внутри batch — тот же upsert, что между вызовами.
    Documents = strip_replacement(Registered, Documents0),
    case free_names([Registered, Canonical], Documents) of
        ok ->
            Stored = Documents#{Registered => Document, Canonical => Document},
            {[Canonical | Canonicals], Errors, Stored};
        {error, Error} ->
            {Canonicals, [{Entry, Error} | Errors], Documents0}
    end.

-spec strip_replacements([uri()], #{uri() => #document{}}) ->
          #{uri() => #document{}}.
strip_replacements(Registrations, Documents) ->
    lists:foldl(fun strip_replacement/2, Documents, Registrations).

-spec strip_replacement(uri(), #{uri() => #document{}}) ->
          #{uri() => #document{}}.
strip_replacement(Registered, Documents) ->
    case maps:get(Registered, Documents, undefined) of
        #document{registered = Registered} = Old -> remove_document(Old, Documents);
        _Other                                -> Documents
    end.

-spec free_names([uri()], #{uri() => #document{}}) ->
          ok | {error, #schema_error{}}.
free_names([], _Documents) ->
    ok;
free_names([Name | Rest], Documents) ->
    case valid_json_metaschema:is_builtin(Name) orelse maps:is_key(Name, Documents) of
        true  -> schema_error({name_taken, Name});
        false -> free_names(Rest, Documents)
    end.

%% Встроенные документы отсюда не видны: они лежат мимо реестра, и `maps:get`
%% их не находит. Тем самым снять встроенное имя нельзя, и отдельного запрета
%% на это не нужно.
-spec remove_names([{uri(), uri()}], #{uri() => #document{}}) ->
          {[{uri(), uri()}], #{uri() => #document{}}}.
remove_names(Names, Documents) ->
    {Removed, Rest} = lists:foldl(fun remove_name/2, {[], Documents}, Names),
    {lists:reverse(Removed), Rest}.

-spec remove_name({uri(), uri()},
                  {[{uri(), uri()}], #{uri() => #document{}}}) ->
          {[{uri(), uri()}], #{uri() => #document{}}}.
remove_name({Entry, Name}, {Removed, Documents}) ->
    case maps:get(Name, Documents, undefined) of
        #document{canonical = Canonical} = Document ->
            {[{Entry, Canonical} | Removed], remove_document(Document, Documents)};
        undefined ->
            {Removed, Documents}
    end.

-spec remove_document(#document{}, #{uri() => #document{}}) ->
          #{uri() => #document{}}.
remove_document(#document{registered = Registered, canonical = Canonical}, Documents) ->
    maps:remove(Canonical, maps:remove(Registered, Documents)).

-spec schema_error(reason()) -> {error, #schema_error{}}.
schema_error(Reason) ->
    {error, #schema_error{reason = Reason, location = undefined}}.

-spec fetch_builtin(uri()) -> #document{} | undefined.
fetch_builtin(Uri) ->
    valid_json_metaschema:fetch(Uri).
