# revit-mcp-setup

Установка **pyRevit 7.0.0** + **RevitMCP** ([oakplank/RevitMCP](https://github.com/oakplank/RevitMCP)) и подключение к **Claude Desktop** на Windows одной командой.

## Установка на новом компьютере

Нужно: Windows, установленный Revit, [Claude Desktop](https://claude.ai/download). Revit на время установки закройте.

1. Скачайте репозиторий: кнопка **Code → Download ZIP** (или `git clone https://github.com/6Nail/revit-mcp-setup.git`) и распакуйте.
2. Откройте PowerShell в папке со скриптом и сначала сделайте пробный запуск (ничего не меняет):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1 -WhatIf
   ```

3. Затем настоящий запуск:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1
   ```

   Если на компьютере нет Python 3.7–3.13, добавьте `-InstallPython`. Чтобы Routes включился автоматически, добавьте `-InstallCli`.
4. Откройте Revit (разрешите загрузку pyRevit), проверьте Routes: **pyRevit → Settings → Routes server**, перезапустите Revit.
5. Полностью закройте Claude Desktop (и значок в области уведомлений) и откройте снова. В **Настройки → Разработчик → Local MCP Servers** у `revitmcp` должен быть статус `running`.
6. Откройте проект в Revit и напишите Claude: `Get Revit project info`.

Все параметры скрипта описаны в начале файла `Install-RevitMCP.ps1` (`Get-Help .\Install-RevitMCP.ps1 -Detailed`).

## Что делает скрипт

1. Проверяет, что Revit закрыт.
2. Скачивает установщик pyRevit 7.0.0 из GitHub Releases, проверяет цифровую подпись и ставит тихо.
3. Клонирует/скачивает RevitMCP в `%APPDATA%\pyRevit\Extensions\RevitMCP.extension`.
4. Находит Python, создаёт окружение `%LOCALAPPDATA%\RevitMCP\venv`, ставит зависимости.
5. Добавляет сервер `revitmcp` в `claude_desktop_config.json` (резервная копия рядом, другие серверы и настройки не трогаются).
6. Пытается включить pyRevit Routes через CLI.

## Откат

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1 -RemoveClaudeEntry
```

Удалить расширение: папка `%APPDATA%\pyRevit\Extensions\RevitMCP.extension`.

## Безопасность

- Скрипт скачивает код из публичных репозиториев (pyRevit, RevitMCP) и запускает его в вашем Revit. Прочитайте скрипт перед запуском.
- RevitMCP умеет **менять модель** (параметры, спецификации, удаление элементов). Для первого запуска используйте тестовую копию проекта.
- Содержимое модели попадает в чат с Claude. Если проект содержит данные, которые нельзя передавать во внешние сервисы, согласуйте использование с ИБ.

## Скилл для Claude

В папке `skill/revit-mcp-setup` лежит скилл (`SKILL.md` + скрипт): с ним Claude сам проведёт установку и диагностику.

## Проверено и не проверено

Синтаксис скрипта проверен в PowerShell 7, логика слияния конфига Claude протестирована на тестовых файлах, имена установщиков pyRevit 7.0.0 подтверждены в GitHub Releases. Полный прогон на Windows с Revit не выполнялся. Команда `pyrevit configs routes enable` не проверена: если не сработает, включите Routes вручную (шаг 4).
