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

`output-test-schema.json` задаёт структуру файлов output suite. Все четыре заявленных формата проверяются официальными fixtures.

# Подтверждение поддержки

Conformance для dialect подтверждается, когда без провалов выполняются:

* основной validation-набор dialect;
* output tests dialect;
* cross-draft tests, чья цепочка dialects целиком входит в заявленный профиль.

Результаты дополнительных capability profiles учитываются и публикуются отдельно.
