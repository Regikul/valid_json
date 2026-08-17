---
type: Test Policy
title: JSON Schema conformance policy
description: Правила проверки Draft 6, Draft 7, Draft 2019-09 и Draft 2020-12, cross-draft ссылок, профиля format и стандартных output formats.
tags: [json-schema, testing, conformance, output]
---

# Conformance-профиль

Проект подтверждает поведение для четырёх JSON Schema dialects:

* `http://json-schema.org/draft-06/schema`;
* `http://json-schema.org/draft-07/schema`;
* `https://json-schema.org/draft/2020-12/schema`;
* `https://json-schema.org/draft/2019-09/schema`.

Профиль включает validation и cross-draft ссылки между всеми этими dialects.
Форматы результата `flag`, `basic`, `detailed`, `verbose` остаются общим
контрактом библиотеки; официальные output fixtures существуют только для Draft
2019-09 и Draft 2020-12.

Test case входит в профиль, если исходный dialect и все dialects, достигнутые через schema references, принадлежат этому набору. При отсутствии `$schema` исходный dialect задаётся директорией suite, из которой загружен test case.

# Validation tests

Test runner выполняет сценарии из:

* `tests/draft2020-12/`;
* `tests/draft2019-09/`;
* `tests/draft7/`;
* `tests/draft6/`.

Файлы непосредственно в директории dialect составляют основной
conformance-набор. Дополнительные capability profiles используют
соответствующие сценарии из `optional/`. Cross-draft профиль выполняет
сценарии, чьи dialects остаются внутри набора из четырёх dialects.

`definitions` является именем schema container во всех поддерживаемых
dialects; `$defs` начинается с Draft 2019-09. В Draft 6/7 обе формы
`dependencies` входят в основной профиль, fragment-only `$id` объявляет
plain-name target текущего resource, а `$ref` игнорирует все siblings. В этих
dialects нет `$vocabulary`, поэтому custom meta-schema наследует полный
фиксированный набор keywords своего draft. Recursive keywords исполняются
только в Draft 2019-09; в Draft 2020-12 они остаются unknown annotations и не
подменяются dynamic keywords.

Для каждого test case runner:

1. загружает `schema` в контексте dialect директории;
2. валидирует каждый `data`;
3. сравнивает полученный результат с `valid`;
4. считает несовпадение, ошибку или аварийное завершение провалом теста.

Из non-format capability profiles во всех четырёх dialects подключены
`optional/bignum.json`, `optional/id.json`, `optional/non-bmp-regex.json` и
`optional/unknownKeyword.json`. В Draft 2019-09 и Draft 2020-12 дополнительно
подключены `optional/anchor.json` и `optional/no-schema.json`. Cross-draft файл
выполняется в Draft 7, Draft 2019-09 и Draft 2020-12, где он присутствует в
закреплённом suite; Draft 2020-12 также выполняет `optional/dynamicRef.json`.

# Профиль format

Это первый capability profile, объявленный отдельно от основного набора. В
него входят поддержанные файлы `optional/format/` всех четырёх dialects:

| Dialect | Подключено файлов | Граница |
| --- | ---: | --- |
| Draft 6 | 10 | все format-файлы закреплённого legacy suite |
| Draft 7 | 14 | кроме четырёх IDN/IRI-файлов |
| Draft 2019-09 | 16 | кроме четырёх IDN/IRI-файлов |
| Draft 2020-12 | 16 | кроме четырёх IDN/IRI-файлов и отдельного ECMA-262 regression-файла |

Схемы профиля компилируются с опцией `{assert_format, true}`: без неё `format` остаётся чистой аннотацией и все cases проходят независимо от содержимого строки. Обязательный `format.json` основного набора, наоборот, компилируется с умолчанием — он закрепляет как раз поведение без вердикта, и включённая проверка проверяла бы там не то, что файл описывает.

Состав поддерживаемых имён, алгоритм каждого и его границы зафиксированы в [«Format attributes»](../architecture/format-attributes.md).

Четыре файла — `idn-email.json`, `idn-hostname.json`, `iri.json`,
`iri-reference.json` — являются документированным исключением профиля там,
где suite их поставляет. Эти имена намеренно остаются чистой аннотацией:
включённая проверка отвечает на них `unsupported`, отчего проходят и те cases,
которые должны провалиться. Подключать файл, который зелен по этой причине,
нечестно, поэтому он не подключается вовсе.

Не входит и `optional/format-assertion.json`, существующий только в Draft 2020-12. Все его cases идут через метасхему, объявляющую Format-Assertion vocabulary значением `true`, а такую метасхему валидатор отвергает — ровно как требует спецификация от реализации без полной проверки всех имён. Документированное исключение четырёх IDN/IRI-имён означает, что библиотека не заявляет поддержку этого vocabulary.

`unknown.json` в профиль входит: незнакомое имя обязано проходить и при включённой проверке, и это отдельное требование, а не следствие отсутствия алгоритма.

# Remote resources

Перед выполнением validation tests runner регистрирует выбранные файлы из `remotes/`. Retrieval URI строится как `http://localhost:1234/` плюс относительный путь файла внутри `remotes/`.

Remote schema обрабатывается согласно собственному `$schema`. Это обеспечивает
cross-draft переходы внутри заявленного conformance-профиля, включая переходы
к Draft 6 и Draft 7.

Для remote document без собственного `$schema` действует то же правило, что и
для test case без `$schema`: dialect задаётся директорией. Это сохраняет
корректный контекст legacy resources и не смешивает dialect точки входа с
dialect соседней директории.

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

Из основного набора Draft 2020-12 исключена группа `^\p{Letter}+$` в
`pattern.json` и `patternProperties.json`. Соответствие диалекту регулярных
выражений ECMA-262 заявлено спецификацией как SHOULD
([core.txt:679](../references/json-schema/draft-2020-12/core.txt)), а `\p{…}` не
входит в подмножество токенов, которым та же спецификация рекомендует
ограничиваться авторам схем
([core.txt:688](../references/json-schema/draft-2020-12/core.txt)). Движком
служит `re` из stdlib, реализующий PCRE; расхождения перечислены и измерены в
[«Адаптации ECMA-262 к PCRE»](../architecture/ecma-to-pcre-adaptation.md).

Из профиля format исключена группа «validation of A-label (punycode) host
names» файла `hostname.json` в Draft 7, Draft 2019-09 и Draft 2020-12 — по
тридцать восемь cases. Draft 6 такой группы не содержит, и его `hostname.json`
подключён целиком. Спецификация задаёт `hostname` через RFC 1123 и punycode
называет только упоминанием, а группа требует большего: декодировать метку
`xn--…` и проверить её содержимое правилами IDNA2008 вплоть до контекста
отдельных символов. Тот же аппарат относится к четырём намеренно исключённым
IDN/IRI-именам
([«Format attributes»](../architecture/format-attributes.md#документированное-исключение-по-idn-и-iri)).

По той же причине, что и первое расхождение, в профиль не входят
`optional/ecmascript-regex.json` всех четырёх dialects и
`optional/format/ecmascript-regex.json` Draft 2020-12. Последний требует
отвергнуть `\a`, который в ECMA-262 не control escape, а в PCRE — обычный BEL.
Это то же расхождение движков, только измеренное отдельным capability profile.

`optional/float-overflow.json` не входит ни в одном из четырёх dialects:
вычисление `multipleOf` над числами, вышедшими за точную область double, не
заявлено. `optional/dependencies-compatibility.json` Draft 2019-09 и Draft
2020-12 также не входит: legacy `dependencies` исполняется только в Draft 6/7.
`optional/refOfUnknownKeyword.json` обоих новых dialects требует считать
значение неизвестного keyword schema position, чего выбранная vocabulary model
не делает.

Draft 7 `optional/content.json` проверяет необязательные content assertions и
потому не входит: библиотека собирает `contentEncoding` и `contentMediaType`
как annotations, но не декодирует содержимое. Annotation-поведение закрепляют
собственные unit и golden tests.

Следующее расхождение сьютом не проявляется и потому объявляется здесь словами: `multipleOf` вычисляется над double, и десятичная дробь, не представимая двоично, может дать ответ, расходящийся с десятичной арифметикой. Ни один сценарий снапшота такого случая не содержит; разбор — в [value model notes](../architecture/validator-value-model-notes.md#доказательство-границы-multipleof).

# Подтверждение поддержки

Runner закрепляет census `{1355, 6125}` — число validation-групп и cases после
всех объявленных исключений. Отдельно закреплены 58 remote documents и census
официального output suite `{8, 8, 8}` — files, cases и запрошенные formats.

Conformance для dialect подтверждается, когда без провалов выполняются:

* основной validation-набор dialect за вычетом перечисленных расхождений;
* output tests dialect, закрепляющие формат `basic`, если для него определены
  официальные output fixtures (Draft 2019-09 и Draft 2020-12);
* собственные golden tests для `flag`, `detailed` и `verbose`, которые официальный suite не покрывает;
* cross-draft tests, чья цепочка dialects целиком входит в заявленный профиль.

Результаты дополнительных capability profiles учитываются и публикуются отдельно.
