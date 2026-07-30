---
type: Architecture
title: JSON Schema assets
description: Назначение runtime-ресурсов JSON Schema и test fixtures, а также граница зависимостей между ними.
tags: [json-schema, architecture, runtime-assets, test-fixtures]
---

# Runtime-ресурсы

Директория [`priv/json_schema/`](../../priv/json_schema/) содержит ресурсы, которые поставляются вместе с OTP-приложением и доступны production-коду:

* `draft-2020-12/schema.json` и `draft-2019-09/schema.json` — корневые meta-schemas поддерживаемых диалектов;
* `draft-*/meta/*.json` — vocabulary meta-schemas;
* `draft-*/output/schema.json` — схемы стандартных форматов результата валидации;
* `UPSTREAM.json` — машиночитаемая привязка ресурсов к коммитам исходного репозитория.

Production-код загружает JSON Schema resources из `priv/json_schema/`. Идентичность schema resource определяется её `$id`; путь внутри `priv/` определяет локальное хранение.

# Test fixtures

Директория [`test/fixtures/json-schema-test-suite/`](../../test/fixtures/json-schema-test-suite/) содержит данные официального conformance suite:

* `tests/draft*/` — сценарии валидации;
* `output-tests/draft*/` — сценарии проверки форматов результата;
* `remotes/draft*/` — удалённые schema resources для тестирования разрешения ссылок;
* `test-schema.json` и `output-test-schema.json` — схемы структуры fixture-файлов;
* `LICENSE` и `UPSTREAM.json` — лицензия и привязка fixtures к исходному коммиту.

Fixtures используются только тестовым кодом и не входят в набор runtime-ресурсов приложения.

# Граница зависимостей

Production-код зависит от `priv/json_schema/`. Test runner зависит от production-кода, runtime-ресурсов и `test/fixtures/json-schema-test-suite/`. Production-код не зависит от fixtures.
