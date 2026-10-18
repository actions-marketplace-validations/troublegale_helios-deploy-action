# Helios ITMO Static Deploy

[![test](https://github.com/troublegale/helios-deploy-action/actions/workflows/test.yml/badge.svg)](https://github.com/troublegale/helios-deploy-action/actions/workflows/test.yml)

GitHub Action для выкладки статического сайта (MkDocs, Sphinx, Pelican, Quarto — любой каталог с HTML)
в файловое хранилище **Helios ИТМО** (`~/public_html` → `https://se.ifmo.ru/~sXXXXXX/`) или на любой
другой хост с SSH и rsync.

Возможности:

- **атомарные релизы**: каждая выкладка загружается в отдельный каталог `~/.deploy/<сайт>/releases/<время>-<sha>`,
  затем симлинк `target` переключается на него через `rename(2)`. Оборванная на середине загрузка не трогает
  опубликованную версию;
- **откат** на предыдущий или указанный релиз (`mode: rollback`), хранится `keep-releases` последних релизов;
- **healthcheck** после выкладки: код ответа 2xx и наличие контрольной строки; при провале — автооткат и красный job;
- **shared-каталоги**, переживающие переключение релизов (например, `preview/` для превью веток);
- `strategy: direct` — обычный `rsync` в каталог с опциональным `--delete`;
- проверка ключа хоста **не отключается**: для Helios ключ хоста закреплён в action, для других хостов
  `known-hosts` обязателен;
- неизменившиеся файлы не передаются повторно и хранятся жёсткими ссылками (`rsync --link-dest`).

## Использование

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    concurrency: helios-deploy        # не допускать параллельных выкладок
    steps:
      - uses: actions/checkout@v7
      # ... сборка сайта в ./site ...
      - uses: troublegale/helios-deploy-action@v1
        with:
          username: s367293
          ssh-key: ${{ secrets.HELIOS_SSH_KEY }}
          source: site
          target: public_html/my-site
          healthcheck-url: https://se.ifmo.ru/~s367293/my-site/
          healthcheck-contains: ${{ github.sha }}
```

Откат (например, из `workflow_dispatch`):

```yaml
      - uses: troublegale/helios-deploy-action@v1
        with:
          username: s367293
          ssh-key: ${{ secrets.HELIOS_SSH_KEY }}
          target: public_html/my-site
          mode: rollback
          rollback-to: ""   # пусто — предыдущий релиз
```

Реальный пример использования — [troublegale/ssg-report](https://github.com/troublegale/ssg-report/blob/main/.github/workflows/site.yml):
основная ветка публикуется в `public_html/ssg-report`, остальные ветки — в `ssg-report/preview/<ветка>/`.

## Параметры

| input | по умолчанию | описание |
|---|---|---|
| `host` | `helios.cs.ifmo.ru` | SSH-хост |
| `port` | `2222` | SSH-порт |
| `username` | — (обязателен) | логин (`sXXXXXX`) |
| `ssh-key` | — (обязателен) | приватный deploy-ключ OpenSSH, только из `secrets` |
| `known-hosts` | ключ Helios | строки `known_hosts`; для хостов, кроме Helios, обязателен |
| `source` | `site` | локальный каталог сборки |
| `target` | — (обязателен) | путь назначения относительно `$HOME`, например `public_html/site` |
| `delete` | `false` | `rsync --delete` (для `strategy: direct`; в `atomic` каждый релиз чистый) |
| `strategy` | `atomic` | `atomic` — релизы и симлинк; `direct` — rsync в каталог |
| `mode` | `deploy` | `deploy`, `rollback`, `remove` (удалить сайт и его релизы) |
| `releases-dir` | `.deploy/<target>` | каталог релизов относительно `$HOME` |
| `keep-releases` | `5` | сколько релизов хранить |
| `shared-dirs` | — | каталоги внутри релиза, заменяемые симлинками на `<releases-dir>/shared/<dir>` |
| `rollback-to` | — | id релиза для отката; пусто — предыдущий |
| `healthcheck-url` | — | URL проверки; пусто — без проверки |
| `healthcheck-contains` | — | контрольная строка в HTML |
| `healthcheck-from` | `runner` | `runner` или `remote` (curl на сервере, если хостинг недоступен из сети раннера) |
| `healthcheck-retries` | `6` | попыток, пауза 5 с |
| `rollback-on-failure` | `true` | автооткат при провале healthcheck |
| `rsync-args` | — | дополнительные аргументы rsync |

| output | описание |
|---|---|
| `release` | активный релиз после выполнения |
| `previous-release` | релиз, активный до выполнения |
| `duration` | длительность доставки, с |

## Совместимость

- Раннер: Linux и macOS (нужны `bash`, `ssh`, `rsync`, `curl`; на `ubuntu-latest` есть из коробки).
  Windows-раннеры не поддерживаются.
- Сервер: POSIX `sh`, `rsync`, `ln`, `mv`; проверено на FreeBSD 14 (Helios, rsync 3.4) и Ubuntu 24.04.
  Атомарная подмена симлинка: `mv -h` (BSD) или `mv -T` (GNU).
- Веб-сервер должен следовать симлинкам (`Options FollowSymLinks`/`SymLinksIfOwnerMatch`) — на Helios это так.

## Безопасность

- Используйте **отдельный** deploy-ключ без пароля только для CI; не используйте личный ключ.
- Закрепляйте action по SHA коммита: `uses: troublegale/helios-deploy-action@<sha> # v1.0.0`.
- Не запускайте выкладку в `pull_request` из форков: секреты там недоступны, и это правильно.
- Пути проверяются на допустимый набор символов и отсутствие `..`: значения не попадают в удалённую
  команду без экранирования.

## Версионирование

Семантическое: теги `vX.Y.Z` и подвижный мажорный тег `v1`, который указывает на последний релиз `v1.*`.

## Лицензия

[MIT](LICENSE)
