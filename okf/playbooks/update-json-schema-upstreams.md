---
type: Playbook
title: Update JSON Schema upstreams
description: Воспроизводимая процедура обновления runtime schemas и официального JSON Schema Test Suite.
tags: [json-schema, maintenance, upstream, fixtures]
---

# Результат

После выполнения процедуры runtime schemas и test fixtures соответствуют явно зафиксированным upstream commits, а локальные проверки подтверждают целостность выбранного conformance-профиля.

# Runtime schemas

Источник runtime schemas — репозиторий `https://github.com/json-schema-org/json-schema-spec`.

Для каждого поддерживаемого dialect:

1. выбрать базовый commit, содержащий согласованный набор опубликованных meta-schema resources;
2. импортировать корневую meta-schema в `priv/json_schema/draft-*/schema.json`;
3. импортировать vocabulary meta-schemas в `priv/json_schema/draft-*/meta/`;
4. выбрать official commit с рабочей версией output schema и импортировать её в `priv/json_schema/draft-*/output/schema.json`;
5. записать базовый commit dialect в [`priv/json_schema/UPSTREAM.json`](../../priv/json_schema/UPSTREAM.json);
6. если output schema происходит из другого commit, записать его в `output.commit` соответствующего dialect.

Repository URL и commits в `UPSTREAM.json` являются машиночитаемой provenance-записью. `commit` dialect применяется к его корневой и vocabulary meta-schemas, а `output.commit` переопределяет источник `output/schema.json`.

# Test fixtures

Источник fixtures — репозиторий `https://github.com/json-schema-org/JSON-Schema-Test-Suite`.

Для зафиксированного commit импортировать:

1. `LICENSE`, `test-schema.json` и `output-test-schema.json`;
2. `tests/draft2020-12/` и `tests/draft2019-09/`;
3. `output-tests/README.md`;
4. `output-tests/draft2020-12/` и `output-tests/draft2019-09/`;
5. remote resources, достижимые из test cases заявленного conformance-профиля;
6. commit suite в [`test/fixtures/json-schema-test-suite/UPSTREAM.json`](../../test/fixtures/json-schema-test-suite/UPSTREAM.json).

Fixture-файлы переносятся из выбранного commit без содержательных изменений. Набор импортированных директорий следует [conformance policy](../testing/conformance-policy.md).

# Проверка

После обновления:

1. разобрать все импортированные JSON-файлы parser-ом, способным загрузить полный официальный corpus, включая escaped UTF-16 surrogate sequences;
2. проверить уникальность и ожидаемые значения канонических `$id`;
3. проверить локальное разрешение `$ref`, `$dynamicRef` и `$recursiveRef` для runtime schemas;
4. проверить наличие remote resources для выполняемых test cases;
5. проверить validation fixtures с помощью `test-schema.json`;
6. проверить output fixtures с помощью `output-test-schema.json`;
7. сверить импортированные файлы с выбранными upstream commits;
8. выполнить `rebar3 compile` и доступные test suites.

# Завершение

Обновление считается завершённым после прохождения проверок и просмотра diff. Изменённые commits фиксируются только в соответствующих `UPSTREAM.json`; Markdown-документы не дублируют их значения.
