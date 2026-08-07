---
type: Test Policy
title: JSON Schema conformance policy
description: Правила проверки Draft 2020-12, Draft 2019-09, Draft 7 и Draft 6, cross-draft ссылок, профиля format и стандартных output formats.
tags: [json-schema, testing, conformance, output]
---

# Conformance-профиль

Проект подтверждает поведение для четырёх JSON Schema dialects:

* `https://json-schema.org/draft/2020-12/schema`;
* `https://json-schema.org/draft/2019-09/schema`.
* `http://json-schema.org/draft-07/schema`.
* `http://json-schema.org/draft-06/schema`.

Профиль включает validation, cross-draft ссылки между всеми четырьмя
диалектами и форматы результата `flag`, `basic`, `detailed`, `verbose`.

Test case входит в профиль, если исходный dialect и все dialects, достигнутые через schema references, принадлежат этому набору. При отсутствии `$schema` исходный dialect задаётся директорией suite, из которой загружен test case.

# Validation tests

Test runner выполняет сценарии из:

* `tests/draft2020-12/`;
* `tests/draft2019-09/`.
* `tests/draft7/`;
* `tests/draft6/`.

Файлы непосредственно в директории dialect составляют основной conformance-набор. Дополнительные capability profiles используют соответствующие сценарии из `optional/`. Cross-draft профиль выполняет сценарии, связывающие все четыре dialects.

`definitions` — реальный keyword Draft 6/7 и совместимое имя `$defs` в обоих
modern dialects. `dependencies` входит в основной набор Draft 6/7 в обеих
формах — property dependency (массив имён) и schema dependency (подсхема) — с
разрешённым пустым массивом; в modern dialects keyword неизвестен.
Modern-only keywords (`$anchor`, `$defs`, `$dynamicRef`, `prefixItems`,
`unevaluated*` и прочие) в Draft 6/7 являются неизвестными и не активируются.
Recursive keywords исполняются только в Draft 2019-09; в Draft 2020-12 они
остаются unknown annotations и не подменяются dynamic keywords.

Для каждого test case runner:

1. загружает `schema` в контексте dialect директории;
2. валидирует каждый `data`;
3. сравнивает полученный результат с `valid`;
4. считает несовпадение, ошибку или аварийное завершение провалом теста.

# Профиль format

Это первый capability profile, объявленный отдельно от основного набора. В него входят файлы `optional/format/` всех четырёх диалектов, кроме перечисленных ниже исключений. Состав файлов per-dialect: у Draft 2020-12 и Draft 2019-09 по шестнадцать файлов, у Draft 7 — четырнадцать (добавлены `date`, `time`, `regex`, `relative-json-pointer`), у Draft 6 — десять; наборы соответствуют официальным спискам format attributes каждого draft.

Схемы профиля компилируются с опцией `{assert_format, true}`: без неё `format` остаётся чистой аннотацией и все cases проходят независимо от содержимого строки. Обязательный `format.json` основного набора, наоборот, компилируется с умолчанием — он закрепляет как раз поведение без вердикта, и включённая проверка проверяла бы там не то, что файл описывает.

Состав поддерживаемых имён, алгоритм каждого и его границы зафиксированы в [«Format attributes»](../architecture/format-attributes.md).

Четыре файла — `idn-email.json`, `idn-hostname.json`, `iri.json`, `iri-reference.json` — являются документированным исключением профиля. Эти имена намеренно остаются чистой аннотацией: включённая проверка отвечает на них `unsupported`, отчего проходят и те cases, которые должны провалиться. Подключать файл, который зелен по этой причине, нечестно, поэтому он не подключается вовсе.

Не входит и `optional/format-assertion.json`, существующий только в Draft 2020-12. Все его cases идут через метасхему, объявляющую Format-Assertion vocabulary значением `true`, а такую метасхему валидатор отвергает — ровно как требует спецификация от реализации без полной проверки всех имён. Документированное исключение четырёх IDN/IRI-имён означает, что библиотека не заявляет поддержку этого vocabulary.

`unknown.json` в профиль входит: незнакомое имя обязано проходить и при включённой проверке, и это отдельное требование, а не следствие отсутствия алгоритма.

`optional/content.json` Draft 7 в профиль не входит. Draft 7 разрешает, но не
требует поддержки `contentEncoding`/`contentMediaType` как validation
assertions (draft-07 validation, 8.3-8.4: «Implementations MAY support the
"contentMediaType" and "contentEncoding" keywords as validation assertions»), а
профиль, как и в modern dialects, держит content keywords чистыми аннотациями.

# Remote resources

Перед выполнением validation tests runner регистрирует выбранные файлы из `remotes/`. Retrieval URI строится как `http://localhost:1234/` плюс относительный путь файла внутри `remotes/`.

Remote schema обрабатывается согласно собственному `$schema`. Это обеспечивает cross-draft переходы внутри заявленного conformance-профиля.

Собственного `$schema` нет у двенадцати файлов снапшота —
`nested-absolute-ref-to-string.json`, `urn-ref-string.json` и
`different-id-ref-string.json` в Draft 2020-12/2019-09 и
`locationIndependentIdentifier.json`, `name.json` и `subSchemas.json` в
Draft 6/7. Для них действует то же правило, что и для test case без
`$schema`: dialect задаётся директорией. Каждый из двенадцати адресуется
только из `refRemote.json` своей директории, поэтому передачи dialect'а вместе
с точкой входа компиляции достаточно и различать источник умолчания для точки
входа и для втянутого по ссылке документа не требуется.

# Output tests

Test runner выполняет сценарии из:

* `output-tests/draft2020-12/`;
* `output-tests/draft2019-09/`.

Для каждого формата, присутствующего в `output` test case, runner:

1. валидирует `data` и запрашивает указанный output format;
2. загружает co-located `output-schema.json` соответствующего dialect как resource с его каноническим `$id`;
3. валидирует фактический output схемой из `output.<format>`;
4. считает непрохождение этой схемы провалом теста.

`output-test-schema.json` задаёт структуру файлов output suite. Он допускает шесть имён форматов — четыре заявленных здесь плюс `list` и `hierarchy` из более поздних черновиков — и требует в test case хотя бы одно.

Снапшот использует из них только `basic`. Официальное покрытие составляют восемь кейсов: по четыре файла в `content/` каждого диалекта, по одному тесту в файле. Форматы `flag`, `detailed` и `verbose` официальными fixtures не проверяются вовсе, поэтому их поведение обязаны закреплять собственные golden tests.

# Известные расхождения

Из основного набора исключена группа `^\p{Letter}+$` в `pattern.json` и `patternProperties.json` всех четырёх диалектов. Соответствие диалекту регулярных выражений ECMA-262 заявлено спецификацией как SHOULD (например, [core.txt:679](../references/json-schema/draft-2020-12/core.txt)), а `\p{…}` не входит в подмножество токенов, которым та же спецификация рекомендует ограничиваться авторам схем ([core.txt:688](../references/json-schema/draft-2020-12/core.txt)). Движком служит `re` из stdlib, реализующий PCRE; расхождения перечислены и измерены в [«Адаптации ECMA-262 к PCRE»](../architecture/ecma-to-pcre-adaptation.md).

Из профиля format исключена группа «validation of A-label (punycode) host names» файла `hostname.json` всех четырёх диалектов. Спецификация задаёт `hostname` через RFC 1123 и punycode называет только упоминанием, а группа требует большего: декодировать метку `xn--…` и проверить её содержимое правилами IDNA2008 вплоть до контекста отдельных символов. Тот же аппарат относится к четырём намеренно исключённым IDN/IRI-именам ([«Format attributes»](../architecture/format-attributes.md#документированное-исключение-по-idn-и-iri)).

По той же причине, что и первое расхождение, в профиль не входит `optional/format/ecmascript-regex.json` Draft 2020-12: его единственный case требует отвергнуть `\a`, который в ECMA-262 не control escape, а в PCRE — обычный BEL. Это то же расхождение движков, только измеренное через `format`, а не через `pattern`.

Следующее расхождение сьютом не проявляется и потому объявляется здесь словами: `multipleOf` вычисляется над double, и десятичная дробь, не представимая двоично, может дать ответ, расходящийся с десятичной арифметикой. Ни один сценарий снапшота такого случая не содержит; разбор — в [value model notes](../architecture/validator-value-model-notes.md#доказательство-границы-multipleof).

# Подтверждение поддержки

Conformance для dialect подтверждается, когда без провалов выполняются:

* основной validation-набор dialect за вычетом перечисленных расхождений;
* output tests dialect, закрепляющие формат `basic`;
* собственные golden tests для `flag`, `detailed` и `verbose`, которые официальный suite не покрывает;
* cross-draft tests, чья цепочка dialects целиком входит в заявленный профиль.

Результаты дополнительных capability profiles учитываются и публикуются отдельно.

Фактический прогон закреплён в runner: 1291 группа и 5967 cases по всем
четырём dialects, 58 remote документов; числа пересчитываются по прогону, а не
подгоняются под ожидание.
