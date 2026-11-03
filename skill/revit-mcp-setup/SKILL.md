---
name: revit-mcp-setup
description: Установка и подключение Revit к Claude Desktop на Windows. Ставит pyRevit 7.0.0, расширение RevitMCP (oakplank/RevitMCP), Python-зависимости и добавляет сервер revitmcp в claude_desktop_config.json. Используй, когда пользователь просит установить или починить pyRevit, Revit MCP, подключить Revit к Claude, изменить конфиг Claude для Revit, или пишет, что revitmcp не виден или не работает.
---

# Установка pyRevit 7.0.0 + RevitMCP и подключение к Claude Desktop

Скрипт `scripts/Install-RevitMCP.ps1` выполняет всю установку одной командой. Работает только в Windows, на том же компьютере, где стоят Revit и Claude Desktop.

## Когда использовать

- Нужно впервые подключить Revit к Claude.
- В Claude Desktop не виден или не работает сервер `revitmcp` (см. «Диагностика»).
- Нужно переустановить или обновить RevitMCP.

## Правила безопасности (соблюдай всегда)

1. Перед запуском объясни пользователю, что скрипт скачивает установщик pyRevit с GitHub, ставит расширение RevitMCP из публичного репозитория и меняет файл конфига Claude Desktop. Получи согласие.
2. Всегда сначала запускай с `-WhatIf` и покажи результат, затем запускай по-настоящему.
3. Не запускай, пока открыт Revit (скрипт сам остановится). Не добавляй `-Force` без явной просьбы пользователя.
4. Не меняй в конфиге Claude ничего, кроме записи `revitmcp`; скрипт сам делает резервную копию с датой в имени.
5. Напомни: RevitMCP умеет изменять модель Revit (параметры, удаление элементов, листы). Для первого запуска используй тестовую копию проекта. Если проект содержит данные, которые нельзя передавать во внешние сервисы, сначала согласуй использование с ИБ: содержимое модели попадает в чат с Claude.

## Запуск

Если у тебя есть доступ к PowerShell на компьютере пользователя:

```powershell
cd <папка со скриптом>\scripts
powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1 -WhatIf
powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1
```

Если доступа нет, передай пользователю эти команды и попроси прислать вывод (или лог из `%TEMP%\revitmcp-install-*.log`).

## Параметры

| Параметр | Значение |
| --- | --- |
| `-PyRevitVersion` | версия pyRevit, по умолчанию `7.0.0` |
| `-Scope User` / `AllUsers` | установка для себя без прав админа (по умолчанию) или для всех (нужен админ) |
| `-InstallPython` | поставить Python 3.13 через winget, если подходящего нет |
| `-PythonPath` | явный путь к `python.exe` (поддерживается 3.7-3.13) |
| `-InstallCli` | поставить pyRevit CLI, чтобы включить Routes автоматически |
| `-NoVenv` | не создавать виртуальное окружение |
| `-SkipPyRevit`, `-SkipRevitMcp`, `-SkipClaudeConfig` | пропустить этап |
| `-RemoveClaudeEntry` | убрать `revitmcp` из конфига Claude |
| `-ClaudeConfigPath` | явный путь к `claude_desktop_config.json` |
| `-RevitMcpRef` | ветка, тег или коммит RevitMCP (по умолчанию `main`) |
| `-Force` | переустановить, пропустить проверку «Revit запущен» |

## Что делает скрипт

1. Проверяет окружение: Windows, Revit закрыт, права.
2. Скачивает `pyRevit_7.0.0.*_signed.exe` из GitHub Releases, проверяет цифровую подпись, тихо ставит (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`).
3. Клонирует или скачивает RevitMCP в `%APPDATA%\pyRevit\Extensions\RevitMCP.extension` (папка должна называться именно так, pyRevit ищет `*.extension`).
4. Находит Python 3.7-3.13, создаёт окружение `%LOCALAPPDATA%\RevitMCP\venv`, ставит `requirements.txt` (Flask, mcp и др.).
5. Добавляет в `claude_desktop_config.json` сервер `revitmcp` с полным путём к `python.exe` и к `server.py`, аргументы `--surface mcp`.
6. Пытается включить pyRevit Routes через CLI; если не вышло, объясняет ручной шаг.

## После скрипта (шаги вручную)

1. Открыть Revit, разрешить загрузку pyRevit в окне безопасности (Always Load).
2. Проверить Routes: Revit > pyRevit > Settings > включить Routes server, перезапустить Revit.
3. Полностью закрыть Claude Desktop (в том числе значок в трее) и открыть снова.
4. Открыть проект в Revit (без открытого проекта инструменты не работают).
5. В Claude Desktop: Настройки > Разработчик > Local MCP Servers: у `revitmcp` статус `running`.
6. Написать Claude: `Get Revit project info`.

## Диагностика

| Симптом | Что проверить |
| --- | --- |
| `revitmcp` нет в списке | JSON конфига валиден; пути абсолютные; Claude Desktop закрыт полностью; логи в `%APPDATA%\Claude\logs` |
| В логе `can't open file ... server.py` | Путь в конфиге не существует: `Test-Path` по пути из конфига; папка расширения называется `RevitMCP.extension` |
| `python` не найден | Скрипт записывает полный путь; для ручной настройки подставь полный путь к `python.exe` |
| Сервер виден, но инструменты не работают | Revit открыт с проектом; Routes включён и Revit перезапущен; Claude и Revit на одном компьютере; брандмауэр |
| Предупреждение Pydantic при Python 3.14 | Использовать Python 3.13 или старше (`-PythonPath`) |
| Лог сервера | `%USERPROFILE%\Documents\RevitMCP\server_logs` |

## Откат

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1 -RemoveClaudeEntry
```

Резервные копии конфига лежат рядом с ним (`claude_desktop_config.json.bak-ДАТА`).

## Источники

- RevitMCP: https://github.com/oakplank/RevitMCP (README: установка, Quick Start для Claude Desktop, Troubleshooting)
- pyRevit релизы: https://github.com/pyrevitlabs/pyRevit/releases (v7.0.0.26278+2233)
- В pyRevit 7.0.0 есть и собственный «agent runtime» с MCP (документация: https://docs.pyrevitlabs.io/agent-runtime/); это отдельный путь, скрипт его не настраивает.
