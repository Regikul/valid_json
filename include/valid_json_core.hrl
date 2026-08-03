%% Контракт вычислительного ядра: модель значения, адресация, IR и результат.
%% Нормативное описание — okf/architecture/validator-core.md.

-ifndef(VALID_JSON_CORE_HRL).
-define(VALID_JSON_CORE_HRL, true).

%% Модель JSON-значения совпадает с результатом json:decode/1.
-type json()      :: null | boolean() | number() | binary()
                   | [json()] | #{binary() => json()}.
-type json_type() :: null | boolean | object | array | number | integer | string.

%% Исходный паттерн хранится рядом с re:mp() ради диагностики.
-type regex() :: {binary(), re:mp()}.

-type uri()     :: binary().
-type pointer() :: binary().                 % от корня resource; <<>> — корень
-type rid()     :: uri() | anonymous.
-type addr()    :: {rid(), pointer()}.
-type dialect() :: uri().

-record(resource, {
    id                       :: uri() | undefined,
    dialect                  :: dialect(),
    anchors                  :: #{binary() => pointer()},
    dynamic_anchors          :: #{binary() => pointer()},
    recursive_anchor = false :: boolean(),
    nodes                    :: #{pointer() => schema_node()}
}).

-record(node, {
    constraints :: [constraint()],
    unevaluated :: [constraint()]
}).

-type compiled() :: #{root      := rid(),
                      sources   := [uri()],
                      resources := #{rid() => #resource{}}}.
-type schema_node() :: boolean() | #node{}.

-type constraint() ::
      {ref, addr()}
    | {dynamic_ref, binary(), addr()}
    | {recursive_ref, addr()}

    | {marker, binary()}

    | {multiple_of, number()}
    | {maximum, number()} | {exclusive_maximum, number()}
    | {minimum, number()} | {exclusive_minimum, number()}
    | {max_length, non_neg_integer()} | {min_length, non_neg_integer()}
    | {pattern, regex()}
    | {max_items, non_neg_integer()} | {min_items, non_neg_integer()}
    | {unique_items, boolean()}
    | {max_properties, non_neg_integer()} | {min_properties, non_neg_integer()}
    | {required, [binary()]}
    | {dependent_required, #{binary() => [binary()]}}
    | {type, [json_type()]}
    | {enum, [json()]}
    | {const, json()}

    | {all_of, [addr()]} | {any_of, [addr()]} | {one_of, [addr()]}
    | {'not', addr()}
    | {if_then_else, addr(), addr() | undefined, addr() | undefined}
    | {dependent_schemas, #{binary() => addr()}}

    | {properties, #{binary() => addr()} | undefined,
                   [{regex(), addr()}] | undefined,
                   addr() | undefined}
    | {property_names, addr()}
    | {items, addr()}
    | {prefix_items, [addr()], addr() | undefined}
    | {items_array, [addr()], addr() | undefined}
    | {contains, addr(),
                 non_neg_integer() | undefined,
                 non_neg_integer() | undefined,
                 MarksEvaluated :: boolean()}

    | {annotation, binary(), json()}
    | {format, binary(), Assert :: boolean()}

    | {unevaluated_properties, addr()}
    | {unevaluated_items, addr()}.

%% Эффективное покрытие для unevaluated*: непрерывный префикс плюс разреженное
%% множество индексов от contains.
-type evaluated()  :: #{properties := sets:set(binary()),
                        items      := items_mask()}.
-type items_mask() :: all
                    | {Prefix :: non_neg_integer(), Sparse :: sets:set(non_neg_integer())}.

%% Локации — обратные стеки сегментов; escaping делается при печати.
-type detail() :: {error, binary()} | {annotation, json()} | none.
-type unit_kind() :: schema | keyword.

-record(output_unit, {
    kind              :: unit_kind(),
    valid             :: boolean(),
    keyword_location  :: [binary()],
    absolute_location :: {uri(), [binary()]} | undefined,
    instance_location :: [binary()],
    detail            :: detail(),
    nested            :: [#output_unit{}]
}).

-record(eval_result, {
    valid     :: boolean(),
    evaluated :: evaluated(),
    units     :: [#output_unit{}]
}).

-type frame() :: {addr(), [binary()]}.

%% node — адрес вычисляемого сейчас node. Отдельного поля под текущий resource
%% нет: это первая половина адреса, а вторая задаёт абсолютную локацию units.
%% coverage говорит, ждёт ли покрытие этого поддерева `unevaluated*` выше по
%% обходу. Пока ждёт, обрывать перебор ветвей нельзя даже в режиме flag: успех
%% первой ветви `anyOf` не отменяет аннотаций остальных.
-record(eval_context, {
    schema            :: compiled(),
    node              :: addr(),
    keyword_location  :: [binary()],
    instance_location :: [binary()],
    dynamic_scope     :: [rid()],
    guard             :: sets:set(frame()),
    mode              :: format(),
    coverage          :: boolean()
}).

%% Ошибка схемы. Текста в записи нет: машинный контракт исчерпывается причиной и
%% локацией, а формулировку вычисляет valid_json_error:format_error/1
%% (okf/architecture/validator-resources-runtime.md, «Ошибки схемы»). Локация
%% называет позицию, значение которой виновато: сам keyword либо schema
%% position. У регистрации локации нет.
-record(schema_error, {
    reason   :: reason(),
    location :: addr() | undefined
}).

%% Каталог причин задан в дизайне и растёт вместе с фазами; здесь перечислено
%% то, что компилятор умеет производить сейчас. `not_implemented` в каталог не
%% входит: это временная причина, которая исчезнет вместе с последним
%% нереализованным keyword.
-type reason() :: invalid_uri
                | invalid_percent_encoding
                | relative_uri_without_base
                | unresolved_anchor
                | {dangling_ref, addr()}
                | {non_schema_target, addr()}
                | {unknown_document, uri()}
                | {unknown_dialect, uri()}
                | {unrecognized_vocabulary, uri()}
                | core_vocabulary_missing
                | {misplaced_keyword, binary()}
                | {name_taken, uri()}
                | {schema_invalid, #output_unit{}}
                | {metaschema_evaluation_failed, uri(), eval_error()}
                | {bad_keyword_value, json()}
                | {bad_pattern, term()}
                | {not_implemented, binary()}.

-type format()     :: flag | basic | detailed | verbose.
-type option()     :: {output, format()}.
-type output()     :: json().
-type eval_error() :: {no_progress, addr()}.

-endif.
