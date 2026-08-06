# Бэкпорт на OTP 20

Разведка и итоговая фиксация бэкпорта: что в библиотеке упирается в современный
OTP, чего это стоит и каким порядком это решено. Пункты в [ROADMAP.md](ROADMAP.md)
этим документом не заводятся.

Приняты два решения, остальное открыто:

- оба тяжёлых модуля stdlib — `uri_string` и `json` — берутся копией из
  исходников OTP, а не заменяются сторонними библиотеками;
- версии разводятся на сборке через `rebar.config.script`, переключающий
  `src_dirs`.

Числа и ссылки на строки сняты со снапшота на момент написания. Документ не
поддерживается автоматически — при смене кода их нужно перепроверять.

## Исходное положение

Изначально `rebar.config` объявлял `{minimum_otp_vsn, "27"}`, CI гонял OTP 27
и OTP 28, а [README.md](README.md) называл причиной требования модуль `json`
из stdlib, появившийся в OTP 27. После бэкпорта минимум изменён на OTP 20;
сборка выбирает vendor-источники по релизу.

Причина названа верно, но она не единственная. Ниже полная опись.

## Общая форма решения

Два самых больших пункта — `uri_string` и `json` — решаются одним приёмом:
файлы копируются из исходников OTP, с них снимаются doc-атрибуты, правится
горстка мест и они кладутся в отдельные каталоги, которые подключаются только
на старом OTP. OTP20 подключает обе копии, OTP21–26 — только `json`, а OTP27+
не подключает ни одну. Работы там на порядок меньше, чем кажется по объёму
файлов.

Побочное следствие важнее, чем выглядит: `{deps, []}` остаётся пустым.
Сторонний JSON-декодер не появляется, а значит модель значения на OTP 20
совпадает с моделью на OTP 27 не «по контракту», а буквально — тем же кодом.
Conformance по декодированию разъехаться не может.

## Что не ломается

Начать стоит с этого, потому что обычно откат назад упирается именно сюда, а
здесь чисто.

- Синтаксис `catch Class:Reason:Stack` (OTP 21) не используется ни разу, как и
  `erlang:get_stacktrace/0`.
- `term_to_binary` и `binary_to_term` не встречаются в репозитории вообще:
  сериализации термов библиотека не делает нигде.
- Не используются `maybe`, sigil-строки, `-doc`/`-moduledoc`, `logger`,
  директивы `-if`/`-elif`, `erlang:phash2`, `counters`, `atomics`.
- Порядок обхода maps и sets нигде не подразумевается неявно: все места, где
  порядок значим, идут через явный `lists:sort` — см.
  [valid_json_object.erl:18](src/valid_json_object.erl#L18) и
  [valid_json_apply.erl:49](src/valid_json_apply.erl#L49). Смена реализации
  `sets` на этом не скажется.

## Опись несовместимостей

### Модули, которых на OTP 20 нет целиком

| Модуль | Появился | Где используется |
| --- | --- | --- |
| `json` | OTP 27.0 | [valid_json_metaschema.erl:104](src/valid_json_metaschema.erl#L104), [valid_json_loader_dir.erl:149](src/valid_json_loader_dir.erl#L149), [valid_json_error.erl:63](src/valid_json_error.erl#L63) (`encode`); в тестах — [valid_json_conformance.erl:193](test/valid_json_conformance.erl#L193), [valid_json_output_conformance.erl:104](test/valid_json_output_conformance.erl#L104), [valid_json_output_golden_tests.erl:420](test/valid_json_output_golden_tests.erl#L420) |
| `uri_string` | OTP 21.0 | URI API через [valid_json_uri_backend.erl](src/valid_json_uri_backend.erl), [valid_json_uri.erl](src/valid_json_uri.erl), [valid_json_format_uri.erl](src/valid_json_format_uri.erl) и [valid_json_store.erl](src/valid_json_store.erl) |

### Функции и BIF'ы

| Вызов | Появился | Где |
| --- | --- | --- |
| `is_map_key/2` (guard BIF) | OTP 21.0 | 6 модулей `src/`, 10 вхождений: [valid_json_apply.erl:49](src/valid_json_apply.erl#L49), [valid_json_assert.erl:84](src/valid_json_assert.erl#L84), [:89](src/valid_json_assert.erl#L89), [valid_json_compile_emit.erl:172](src/valid_json_compile_emit.erl#L172), [:304](src/valid_json_compile_emit.erl#L304), [:548](src/valid_json_compile_emit.erl#L548), [valid_json_object.erl:81](src/valid_json_object.erl#L81), [:98](src/valid_json_object.erl#L98), [valid_json_resource_index.erl:443](src/valid_json_resource_index.erl#L443), [valid_json_uri.erl:153](src/valid_json_uri.erl#L153) |
| `atom_to_binary/1` | OTP 23.0 | [valid_json_assert.erl:134](src/valid_json_assert.erl#L134), [:191](src/valid_json_assert.erl#L191) |
| `sets:new/1`, `sets:from_list/2` (`{version, 2}`) | OTP 24.0 | [valid_json_evaluated.erl:13-29](src/valid_json_evaluated.erl#L13-L29), [valid_json_eval.erl:17](src/valid_json_eval.erl#L17) |
| `lists:enumerate/2` | OTP 25.0 | [valid_json_array.erl:82](src/valid_json_array.erl#L82) |
| `filelib:safe_relative_path/2` | OTP 23.0 | [valid_json_loader_dir.erl:201](src/valid_json_loader_dir.erl#L201) |
| `handle_continue/2` (gen_server) | OTP 21.0 | [valid_json_store_manager.erl:301](src/valid_json_store_manager.erl#L301) |
| `uri_string:resolve/2` | OTP 22.0 | [valid_json_uri_backend.erl](src/valid_json_uri_backend.erl): fallback для OTP 20–21 |

### Только в тестах

`lists:search/2` (OTP 21, четыре места), `maps:from_keys/2` (OTP 24,
[valid_json_uri_tests.erl:168](test/valid_json_uri_tests.erl#L168)),
`filelib:ensure_path/1` (OTP 25), `file:del_dir_r/1` (OTP 23), `ets:whereis/1`
(OTP 21, см. оговорку в конце документа),
`lists:enumerate/2` ([valid_json_eval_tests.erl:1577](test/valid_json_eval_tests.erl#L1577),
[:1588](test/valid_json_eval_tests.erl#L1588)).

## Разбор по пунктам

### `uri_string` — копия из stdlib

Выглядит как самая большая работа и ею не является. Модуль `uri_string.erl`
самодостаточен: около 2400 строк, ни одного `-include`, ни одного behaviour.
После удаления doc-атрибутов снаружи он зовёт только это:

```
binary:last                      lists:filter/member/reverse/seq
inet:parse_ipv4strict_address    maps:fold/get/is_key/map/merge/remove/with
inet:parse_ipv6strict_address    proplists:get_value
string:split                     unicode:characters_to_binary/characters_to_list
```

Всё доступно на OTP 20. Самый молодой пункт — `string:split/2,3`, он появился
ровно в OTP 20.0 вместе с новым unicode-модулем `string`. Внутри нет ни
`is_map_key`, ни `erlang:error/3`, ни синтаксиса стектрейса, ни `-if`/`-elif`,
ни `persistent_term`.

Единственная несовместимость — сами атрибуты `-moduledoc` и `-doc` с
triple-quoted строками: это синтаксис OTP 27, старый сканер на нём споткнётся.
Снимаются механически, тремя регулярками в один проход.

**Какую версию брать.** Не всё равно, и «что постарее» — ловушка.

| | `percent_decode/1` | `quote/1,2`, `unquote/1` |
| --- | --- | --- |
| OTP 22.3.4.27 | нет | нет |
| OTP 23.3.4.20 | есть | нет |
| OTP 24.3.4.17 | есть | нет |
| OTP 27.2, 28.1.1 | есть | есть |

Библиотека использует оба: `percent_decode/1` в
[valid_json_uri.erl:127](src/valid_json_uri.erl#L127) и `quote/2` в
[valid_json_loader_dir.erl:162](src/valid_json_loader_dir.erl#L162).

Довод посильнее — нормализация. Между OTP 24 и 27 в ней изменились две вещи:
добавился шаг `normalize_undefined_port`, и в `normalize_path_segment` дефолт
пути сменился с `undefined` на `<<>>`. Каноническая форма служит ключом реестра
документов ([valid_json_uri.erl:91-100](src/valid_json_uri.erl#L91-L100)), так
что версия постарее тихо поменяет имена документов для URI без пути вроде
`https://example.com`, и conformance разъедется не там, где будешь искать.

Брать надо файл из **OTP 28.1.1**: с вырезанными доками он отличается от 27.2
ровно четырьмя строками, и все четыре — в шапке (строка SPDX и годы в
копирайте). Код байт в байт тот же, на котором библиотека тестируется сейчас.

**Почему не сторонняя библиотека.** Готовой замены в экосистеме нет и не было.
До OTP 21 в самой OTP был `http_uri` из inets, он есть и на OTP 20, но
разбирает URI в кортеж, требует абсолютной ссылки со схемой и не умеет ни
разрешения относительных ссылок, ни нормализации; документация OTP про него
говорит прямо, что он не удовлетворяет RFC. Именно поэтому в OTP 21 завели
новый модуль, а не чинили старый. Сторонние библиотеки повторяют ту же картину:
`urilib` даёт `parse`/`build`/percent-кодирование без §5.2 и §6.2.2 (репозиторий
заархивирован), `hackney_url` и `mochiweb_util:urlsplit` — split/join для
HTTP-клиентов. Разрешение относительной ссылки и syntax-based normalization —
ровно те части, которые HTTP-клиенту не нужны, а нужны JSON Schema `$ref`, XML
Base и RDF, поэтому их либо писали руками под свою задачу, либо не решали вовсе.

### `json` — тоже копия, и правок там меньше

Копируются два файла: `json.erl` (1474 строки, после снятия доков 1150) и
`json.hrl`, который он включает (189 строк, шесть `-define`, ни одной внешней
ссылки и ни одной современной конструкции).

Весь набор внешних вызовов `json.erl` после снятия доков:

```
binary:at            lists:duplicate/foldl/map/reverse    string:next_codepoint
erlang:iolist_size   maps:fold/from_list/iterator/merge/to_list    string:take
```

Дальше начинается приятное. Почти всё version-sensitive сидит в секции `format`
— это pretty-printer, добавленный в OTP 27.1, и библиотека его не вызывает
вообще. В той части, которой библиотека реально пользуется, блокеров четыре:

| Что | Версия | Где (нумерация по файлу со снятыми доками) |
| --- | --- | --- |
| `float_to_binary(Float, [short])` | опция `short` — OTP 24.0 | 141, `encode_float/1` |
| `is_map_key/2` | OTP 21.0 | 179, `do_encode_checked/3` |
| `erlang:error/3` | OTP 24.0 | 392, `invalid_byte/2` |
| `erlang:error/3` | OTP 24.0 | 1150, `unexpected_sequence/2` |

Ещё тринадцать мест — в неиспользуемой секции `format`:

| Что | Версия | Где |
| --- | --- | --- |
| `maps:iterator/2` с `ordered` | OTP 26.0 | 442, `format_value/3` |
| `is_map_key/2` | OTP 21.0 | 519, `do_format_checked/3` |
| 11 сигилов `~"\n  "` | синтаксис OTP 27 | 552–562, `steps/1` |

Правки механические. `is_map_key/2` в обоих местах стоит в `case`, а не в
guard, и меняется на `maps:is_key/2`. Оба `error/3` теряют второй и третий
аргументы: третий несёт только EEP-54 metadata для форматирования в шелле, а
reason остаётся тем же термом, и внешнее поведение не меняется.
`maps:iterator(Map, ordered)` заменяется на `lists:sort(maps:to_list(Map))` —
это ровно то, что упорядоченный итератор и даёт. Сигилы — на `<<"...">>`.

`string:take/2,3` и `string:next_codepoint/1` из секции `format` править не
надо: обе появились в OTP 20.0, как и `string:split`.

**Цена опции `short`.** Она даёт кратчайшее представление float'а с
round-trip; на OTP 20 эквивалента нет. `float_to_binary/1` вернёт
`1.00000000000000000000e+00` — двадцати знаков хватает для round-trip, так что
JSON остаётся корректным, просто длиннее.

Задеть это может только одно место: `json:encode` вызывается в проекте ровно
один раз, в [valid_json_error.erl:63](src/valid_json_error.erl#L63), при
рендере `bad_keyword_value` в текст сообщения. Тесты сверяют терм, а не строку
(см. `valid_json_resource_index_tests`), так что на OTP 20 float в одном
сообщении об ошибке напечатается длинно, и это вся цена.

Декодер — та половина, ради которой всё и делается, — чистый целиком:
`binary_part/3`, `binary:at`, `maps:from_list`, `lists:reverse`,
`erlang:binary_to_float/1`, `erlang:binary_to_integer/1`.

**Какую версию брать.** Снова OTP 28.1.1. Разница с 27.2 при снятых доках — 15
строк: замена `"{"` на `${` в нескольких местах (микрооптимизация) и
добавление `module => erl_stdlib_errors` в `error_info/1`, которое всё равно
уходит вместе с `error/3`. `json.hrl` отличается только шапкой.

**Выкидывать ли `format`.** Можно: библиотека его не зовёт, и тогда тринадцать
правок из второй таблицы исчезают сами. Предпочтительнее оставить и сделать
правки: проверка в CI, диффящая копию против upstream, тем осмысленнее, чем
меньше от upstream отличий.

### Лицензия на вендоренные файлы

Касается всех трёх: `uri_string.erl`, `json.erl`, `json.hrl`.

Копирование разрешено прямо. Все три под Apache 2.0 с копирайтом
`Ericsson AB`, проект — тоже Apache 2.0, см. [LICENSE.md](LICENSE.md). Файла
`NOTICE` у OTP нет, в корне дерева лежит только `LICENSE.txt` с дословным
текстом лицензии. Из четырёх условий §4 три уже выполнены самим фактом
совпадения лицензий, а четвёртое требует пометить изменённый файл:

- §4(a) копия лицензии получателю — `LICENSE.md` в корне;
- §4(b) заметное уведомление об изменении файла — **надо добавить**;
- §4(c) сохранить все уведомления об авторстве — блок `%% Copyright Ericsson
  AB ... %% %CopyrightEnd%` остаётся в файле дословно, вырезать его нельзя;
- §4(d) содержимое `NOTICE` — не применимо, у OTP его нет.

§6 не даёт прав на имена «Erlang», «Erlang/OTP», «Ericsson», кроме описания
происхождения — а описать происхождение как раз и требуется.

Шапка должна выглядеть так:

```erlang
%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2017-2025. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% ... (весь текст без изменений) ...
%%
%% %CopyrightEnd%
%%
%% MODIFIED COPY. Source: lib/stdlib/src/uri_string.erl from Erlang/OTP*
%% 28.1.1. Changes: removed -moduledoc/-doc attributes (OTP 27+ syntax,*
%% incompatible with OTP 20). Logic unchanged.*
```

Имена модулей менять не нужно: на OTP 20 столкнуться со stdlib они не могут, а
на новом OTP не компилируются вовсе — см. следующий раздел.

Стоит завести `THIRD_PARTY.md` со списком: что вкомпилировано, откуда, какой
версии, под какой лицензией. Формально §4 закрывается шапкой в файле, но при
публикации на hex это то, что люди ожидают увидеть.

### `persistent_term` — заменён на ETS

Публикация одноразовая, при старте приложения; чтения идут по пути регистрации и
компиляции схемы, а не на горячем пути `validate`. Замер это подтвердил: строка
таблицы занимает 17944 слова (около 140 КБ), одно чтение стоит около 30 мкс, а
на регистрацию схемы приходится ровно одно чтение при общей стоимости регистрации
около 14,6 мс — 0,2%.

Встроенная область живёт в защищённой ETS под собственной веткой супервизора
`valid_json_metaschema_sup`: хранитель таблицы и владелец, публикующий bundle в
`init/1`. Фолбэка на ленивую публикацию нет: обращение к метасхеме при
незапущенном приложении кончается ошибкой `{application_not_started, valid_json}`.

### `handle_continue` — теряется гарантия, а не функция

Комментарий на [valid_json_store_manager.erl:23](src/valid_json_store_manager.erl#L23)
опирается на то, что пересборка идёт до первого обслуженного сообщения. Замена
на self-cast из `init/1` эту гарантию не даёт: имя регистрируется до вызова
`init/1`, и чужое сообщение может лечь в почтовый ящик раньше нашего каста.

Честный эквивалент на OTP 20 — выполнить пересборку прямо в `init/1`, ценой
того, что `gen_server:start_link` не вернётся до её конца, а ошибка пересборки
станет отказом старта, а не отдельной веткой.

### Мелочи

- `is_map_key/2` в guard — на паттерн `#{K := _}`; вне guard — на
  `maps:is_key/2`.
- `atom_to_binary/1` — на `atom_to_binary/2` с `utf8`.
- `sets` версии 2 — на версию 1. Семантика используемых функций
  (`add_element`, `del_element`, `is_element`, `union`, `filter`, `to_list`)
  та же, порядок нигде не важен.
- `lists:enumerate/2` — три строчки на `lists:zip(lists:seq(...), ...)`.
- `filelib:safe_relative_path/2` придётся написать самому. Это защитный код: он
  не пускает загрузчик каталога наружу `priv`, и переписывать его надо
  внимательно.

## Механика сборки

Версии разводятся через `rebar.config.script` — файл рядом с `rebar.config`,
который rebar3 выполняет при загрузке конфигурации. Переменная `CONFIG` держит
разобранный `rebar.config`, возвращённое значение становится итоговой
конфигурацией.

```erlang
%% rebar.config.script
%% json отсутствует до OTP 27, uri_string:resolve/2 — до OTP 22.
Release = list_to_integer(erlang:system_info(otp_release)),
Dirs = case Release of
           R when R < 21 -> ["src", "vendor/json", "vendor/uri_string"];
           R when R < 27 -> ["src", "vendor/json"];
           _             -> ["src"]
       end,
FeatureFlags =
    [{d, 'CAP_URI_PERCENT_DECODE'} || Release >= 23] ++
    [{d, 'CAP_URI_QUOTE'} || Release >= 25] ++
    [{d, 'CAP_FLOAT_TO_BINARY_SHORT'} || Release >= 25] ++
    [{d, 'CAP_ETS_INFO_ID'} || Release >= 21] ++
    [{d, 'CAP_URI_RESOLVE'} || Release >= 22],
{erl_opts, ErlOpts} = lists:keyfind(erl_opts, 1, CONFIG),
Config = lists:keystore(erl_opts, 1, CONFIG,
                         {erl_opts, ErlOpts ++ FeatureFlags}),
lists:keystore(src_dirs, 1, Config, {src_dirs, Dirs}).
```

Проверено на rebar3 3.27 / OTP 27: в `ebin` попадают только модули из `src`.
На OTP 21–26 добавляется только вендоренный `json`, а на OTP20 добавляются
оба вендоренных модуля.

**Ловушка: `src` обходится рекурсивно.** Положить копии в `src/vendor/` нельзя
— они скомпилируются, несмотря на `src_dirs = ["src"]`. Каталог с копиями
должен лежать **вне** `src`, отдельным `vendor/` в корне проекта. Первый макет
попался ровно на этом.

Отсюда же следует, что переименовывать вендоренные модули не нужно: на новом
OTP они просто не компилируются, а на OTP 20 столкнуться со stdlib не могут.
Для отсутствующего на OTP 21 `uri_string:resolve/2` отдельный backend
предоставляет fallback сам; остальные URI-вызовы проходят через него и
выбирают системный либо вендоренный модуль по сборке.

**Отвергнутый вариант: `{platform_define, Regex, Macro}`.** Штатный механизм
rebar3, включающий макрос для `-ifdef` по версии OTP. Он работает, но требует
`-ifdef` внутри каждого затронутого модуля, то есть протаскивает версию OTP в
`src/`, — и несёт ловушку, на которую легко попасться. Регулярка сверяется не с
номером релиза, а со строкой вида `"27.2-x86_64-pc-linux-gnu-64"`: полная
версия OTP, потом архитектура, потом разрядность. Замер перебором на OTP 27.2:

| Регулярка | Сработала |
| --- | --- |
| `"27"` | да |
| `"^2[0-9]\\."` | да |
| `"^27\\.2-"` | да |
| `"^2[0-9]-"` | **нет** |
| `"^(1[0-9]\|20)$"` | **нет** |

Очевидные на вид формы молча не срабатывают: макрос не определяется,
компилируется не та ветка, ошибки при этом нет. Для OTP 20 правильная форма —
`"^20\\."`. Если механизм всё же понадобится, это надо помнить.

**Проверка в CI.** Замороженная копия перестаёт получать чужие исправления,
поэтому нужен шаг, диффящий каждый файл в `vendor/` против одноимённого файла
из исходников текущего OTP. Расхождение должно быть видно сразу, а не через
полгода.

## Инструментальная часть

Строка `{minimum_otp_vsn, "20"}` сама по себе не проблема. Проблема в том, что
установленный rebar3 3.27 собран под современный OTP: поддержка OTP 20 в rebar3
отвалилась несколько лет назад, и понадобится старая ветка — район 3.15–3.16,
точную границу надо проверять по их changelog.

Профиль `ci` с `warnings_as_errors` на OTP 20 почти наверняка загорится: набор
предупреждений компилятора там другой. Отдельно стоит проверить, не ругается ли
он на вендоренные файлы: в `json.erl` стоит `-compile(warn_missing_spec)`.

Директивы `-if`/`-elif` для разведения версий не годятся — они сами из OTP 21.

## Чего нельзя оценить без стенда

Регулярные выражения.
[ecma-to-pcre-adaptation](okf/architecture/ecma-to-pcre-adaptation.md) сам
предупреждает, что все числа сняты на OTP 27 однажды и при смене версии OTP их
надо снимать заново вручную. OTP 20 несёт другую версию PCRE, а расхождения с
ECMA-262, описанные в том документе, целиком держатся на `\p{…}`, `\w` и `\s` —
ровно на том, что от версии PCRE и зависит. Conformance-профиль на OTP 20 может
дать другой результат, и предсказать его на бумаге нельзя.

То же касается общего прогона сьюта: OTP 20 в текущем стенде не установлен,
поэтому его точный runtime/conformance результат остаётся непроверенным.

## Порядок работ

1. Стенд: OTP 20 через asdf и старая ветка rebar3. Задача этого шага — не
   починить, а увидеть настоящий список ошибок компиляции.
2. `rebar.config.script` и каталоги `vendor/json/`, `vendor/uri_string/`:
   механика сборки ставится до того, как в неё попадают вендоренные модули.
3. Мелочи из соответствующего раздела: они дешёвые и убирают шум из вывода
   компилятора.
4. `json`: скопировать `json.erl` и `json.hrl`, снять доки, сделать четыре
   правки в используемой части и тринадцать в `format`. Приёмка — conformance,
   он весь идёт через декодер.
5. `uri_string`: скопировать файл, снять доки. Приёмка — тесты URI-слоя.
6. `handle_continue`: он трогает запуск приложения и его удобно делать после
   разведения версий stdlib.
7. Проверка в CI на расхождение `vendor/` с upstream.
8. Снять conformance-числа на OTP 20 и сравнить с текущими. Расхождения по
   регуляркам ожидаемы; всё остальное — регресс.

## Что осталось непроверенным

- Точная граница версий rebar3 с поддержкой OTP 20 — по changelog rebar3 не
  сверялась.
- Версия появления `ets:whereis/1` в таблице тестовых зависимостей взята по
  памяти и требует сверки с changelog OTP.
- Совпадает ли поведение `inet:parse_ipv6strict_address/1` на OTP 20 и OTP 27 —
  вендоренный `uri_string` зовёт её при разборе authority, а обработка zone id
  между версиями могла меняться.
- Не проверялось, компилируются ли вендоренные файлы на OTP 20 на самом деле.
  Вывод сделан по описи внешних вызовов и синтаксиса, а не прогоном компилятора:
  стенда с OTP 20 пока нет.
