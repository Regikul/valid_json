%% Фасад библиотеки. Переводит публичный вызов во внутренний и делегирует;
%% решений не принимает, и вся работа сверх делегирования состоит в том, чтобы
%% развести опции двух слоёв по их слоям. Области описаны в
%% okf/architecture/validator-design.md.
-module(valid_json).

-include("valid_json_core.hrl").
-include("valid_json_resources.hrl").

-export([run_schema/3]).

-export([add/1, add_at/1, add_at/2, remove/1, wait/1, validate/3]).

-export([store_child_spec/2, store_add/2, store_add_at/2, store_add_at/3,
         store_remove/2, store_wait/2, store_validate/4]).

-export([format_error/1]).

%% Схема называет себя сама: имя документа — его `$id`, и требовать имени рядом
%% незачем. Список нужен потому, что резолв не ленивый: взаимно ссылающиеся
%% документы обязаны попасть в реестр одним вызовом. Пар этот вход не берёт —
%% для них есть `add_at`, и одно имя не значит двух правил именования.
-spec add(json() | [json()]) ->
          {ok, [uri()]} | {error, valid_json_store_manager:add_error()}.
add(Schemas) when is_list(Schemas) ->
    store_add(?STANDARD_STORE, Schemas);
add(Schema) ->
    add([Schema]).

%% Форма для случая, когда имя есть снаружи: схема взята по этому адресу, и он
%% же становится её именем, если `$id` она не объявила. Отличается от `add/1`
%% именем функции, а не устройством аргумента.
-spec add_at(uri(), json()) ->
          {ok, [uri()]} | {error, valid_json_store_manager:add_error()}.
add_at(Uri, Json) ->
    add_at([{Uri, Json}]).

-spec add_at([{uri(), json()}]) ->
          {ok, [uri()]} | {error, valid_json_store_manager:add_error()}.
add_at(Entries) ->
    store_add_at(?STANDARD_STORE, Entries).

-spec remove([uri()]) -> ok | {error, [{uri(), #schema_error{}}]}.
remove(Uris) ->
    store_remove(?STANDARD_STORE, Uris).

%% Первая операция того, кто собирается читать: дожидается конца загрузки и
%% отдаёт монитор, по которому вызывающий узнает, что состав мог измениться.
-spec wait(timeout()) -> {ok, reference()} | {error, timeout}.
wait(Timeout) ->
    store_wait(?STANDARD_STORE, Timeout).

%% Первым аргументом идёт имя схемы, а не сама схема: встроенный режим живёт под
%% отдельным именем `run_schema/3`. Различает их имя функции, а не форма
%% аргумента: одна арность не должна значить двух разных вещей.
-spec validate(uri(), json(), [option()]) ->
          {ok, output()} | {error, not_found} | {error, unavailable}
        | {error, eval_error()}.
validate(Uri, Instance, Options) ->
    store_validate(?STANDARD_STORE, Uri, Instance, Options).

%% Встроенный режим одним вызовом: схема компилируется здесь же, в процессе
%% вызывающего, и сразу вычисляет инстанс. Ни хранилища, ни запущенного
%% приложения для этого не нужно — встроенные метасхемы публикуются по первому
%% обращению.
%%
%% Реестр у такой компиляции временный, поэтому схема обязана быть
%% самодостаточной: `$ref` видит только её саму и встроенные метасхемы, а
%% зарегистрированные документы любого хранилища ей не видны. Относительный
%% `$id` разрешать не от чего — базы у временного реестра нет.
%%
%% Артефакт нигде не остаётся, и каждый вызов заново проходит discovery,
%% meta-validation (если не задано `{trust_schema, true}`), компиляцию паттернов
%% и эмиссию IR. Дверь эта разовая:
%% схему, которой пользуются больше одного раза, дешевле зарегистрировать и
%% звать `validate/3`.
-spec run_schema(json(), json(),
                 [option() | valid_json_compile:compile_option()]) ->
          {ok, output()} | {error, #schema_error{}} | {error, eval_error()}.
run_schema(Schema, Instance, Options) ->
    {EvalOptions, CompileOptions} = split_options(Options),
    case valid_json_compile:compile(valid_json_store:temporary(), Schema,
                                    CompileOptions) of
        {ok, Compiled}     -> valid_json_core:validate(Compiled, Instance,
                                                       EvalOptions);
        {error, _} = Error -> Error
    end.

%% Опции обоих слоёв приходят одним списком: вызывающему это опции одного
%% вызова, а не двух. Ядру принадлежит `output`, всё прочее уходит компилятору,
%% и незнакомый ключ падает badarg там же, где падал бы при прямом вызове.
-spec split_options([term()]) ->
          {[option()], [valid_json_compile:compile_option()]}.
split_options(Options) ->
    lists:partition(fun({output, _Format}) -> true;
                       (_Other)            -> false
                    end, Options).

%% Единственная из семьи `store_*` без пары без приставки: стандартное хранилище
%% библиотека ставит в своё дерево сама, а встраивать нужно только собственное.
%% Спека принадлежит супервизору хранилища, фасад её только пересказывает — чтобы
%% за ней не идти в исходники.
-spec store_child_spec(atom(), [valid_json_store_manager:store_option()]) ->
          supervisor:child_spec().
store_child_spec(Store, Options) ->
    valid_json_store_sup:child_spec(Store, Options).

-spec store_add_at(atom(), uri(), json()) ->
          {ok, [uri()]} | {error, valid_json_store_manager:add_error()}.
store_add_at(Store, Uri, Json) ->
    store_add_at(Store, [{Uri, Json}]).

-spec store_add_at(atom(), [{uri(), json()}]) ->
          {ok, [uri()]} | {error, valid_json_store_manager:add_error()}.
store_add_at(Store, Entries) ->
    valid_json_store_manager:add_at(Store, Entries).

-spec store_add(atom(), json() | [json()]) ->
          {ok, [uri()]} | {error, valid_json_store_manager:add_error()}.
store_add(Store, Schemas) when is_list(Schemas) ->
    valid_json_store_manager:add(Store, Schemas);
store_add(Store, Schema) ->
    store_add(Store, [Schema]).

-spec store_remove(atom(), [uri()]) ->
          ok | {error, [{uri(), #schema_error{}}]}.
store_remove(Store, Uris) ->
    valid_json_store_manager:remove(Store, Uris).

-spec store_wait(atom(), timeout()) -> {ok, reference()} | {error, timeout}.
store_wait(Store, Timeout) ->
    valid_json_store_manager:wait(Store, Timeout).

%% Имя принимается и коротким: `lookup` разрешает его от базы хранилища тем же
%% правилом, каким разрешается регистрируемое. `unavailable` означает, что до
%% чтения дело не дошло: хранилище ещё не готово или перезапускается.
-spec store_validate(atom(), uri(), json(), [option()]) ->
          {ok, output()} | {error, not_found} | {error, unavailable}
        | {error, eval_error()}.
store_validate(Store, Uri, Instance, Options) ->
    case valid_json_store_manager:lookup(Store, Uri) of
        {ok, Compiled}       -> valid_json_core:validate(Compiled, Instance, Options);
        {error, _Reason} = E -> E
    end.

-spec format_error(#schema_error{} | eval_error()) -> unicode:chardata().
format_error(Error) ->
    valid_json_error:format_error(Error).
