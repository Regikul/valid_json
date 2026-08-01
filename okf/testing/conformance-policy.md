---
type: Test Policy
title: JSON Schema conformance policy
description: Правила проверки Draft 2020-12 и Draft 2019-09, cross-draft ссылок и стандартных output formats.
tags: [json-schema, testing, conformance, output]
---

# Conformance-профиль

Проект подтверждает поведение для двух JSON Schema dialects:

* `https://json-schema.org/draft/2020-12/schema`;
* `https://json-schema.org/draft/2019-09/schema`.

Профиль включает validation, cross-draft ссылки между этими диалектами и форматы результата `flag`, `basic`, `detailed`, `verbose`.

Test case входит в профиль, если исходный dialect и все dialects, достигнутые через schema references, принадлежат этому набору. При отсутствии `$schema` исходный dialect задаётся директорией suite, из которой загружен test case.

# Validation tests

Test runner выполняет сценарии из:

* `tests/draft2020-12/`;
* `tests/draft2019-09/`.

Файлы непосредственно в директории dialect составляют основной conformance-набор. Дополнительные capability profiles используют соответствующие сценарии из `optional/`. Cross-draft профиль выполняет сценарии, связывающие Draft 2020-12 и Draft 2019-09.

Для каждого test case runner:

1. загружает `schema` в контексте dialect директории;
2. валидирует каждый `data`;
3. сравнивает полученный результат с `valid`;
4. считает несовпадение, ошибку или аварийное завершение провалом теста.

# Remote resources

Перед выполнением validation tests runner регистрирует выбранные файлы из `remotes/`. Retrieval URI строится как `http://localhost:1234/` плюс относительный путь файла внутри `remotes/`.

Remote schema обрабатывается согласно собственному `$schema`. Это обеспечивает cross-draft переходы внутри заявленного conformance-профиля.

Собственного `$schema` нет у шести файлов снапшота — `nested-absolute-ref-to-string.json`, `urn-ref-string.json` и `different-id-ref-string.json` в обоих диалектах. Для них действует то же правило, что и для test case без `$schema`: dialect задаётся директорией. Каждый из шести адресуется только из `refRemote.json` своей директории, поэтому передачи dialect'а вместе с точкой входа компиляции достаточно и различать источник умолчания для точки входа и для втянутого по ссылке документа не требуется.

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

Из основного набора исключена группа `^\p{Letter}+$` в `pattern.json` и `patternProperties.json` обоих диалектов. Соответствие диалекту регулярных выражений ECMA-262 заявлено спецификацией как SHOULD ([core.txt:679](../references/json-schema/draft-2020-12/core.txt)), а `\p{…}` не входит в подмножество токенов, которым та же спецификация рекомендует ограничиваться авторам схем ([core.txt:688](../references/json-schema/draft-2020-12/core.txt)). Движком служит `re` из stdlib, реализующий PCRE; расхождения перечислены и измерены в [«Адаптации ECMA-262 к PCRE»](../architecture/ecma-to-pcre-adaptation.md).

Второе расхождение сьютом не проявляется и потому объявляется здесь словами: `multipleOf` вычисляется над double, и десятичная дробь, не представимая двоично, может дать ответ, расходящийся с десятичной арифметикой. Ни один сценарий снапшота такого случая не содержит; разбор — в [value model notes](../architecture/validator-value-model-notes.md#доказательство-границы-multipleof).

# Подтверждение поддержки

Conformance для dialect подтверждается, когда без провалов выполняются:

* основной validation-набор dialect за вычетом перечисленных расхождений;
* output tests dialect, закрепляющие формат `basic`;
* собственные golden tests для `flag`, `detailed` и `verbose`, которые официальный suite не покрывает;
* cross-draft tests, чья цепочка dialects целиком входит в заявленный профиль.

Результаты дополнительных capability profiles учитываются и публикуются отдельно.
