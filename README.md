# revit-mcp-setup

Установка **pyRevit 7.0.0** + **RevitMCP** ([oakplank/RevitMCP](https://github.com/oakplank/RevitMCP)) и подключение к **Claude Desktop** на Windows одной командой.

## Установка на новом компьютере

Нужно: Windows, установленный Revit, [Claude Desktop](https://claude.ai/download). Revit на время установки закройте.

1. Скачайте репозиторий: кнопка **Code → Download ZIP** (или `git clone https://github.com/6Nail/revit-mcp-setup.git`) и распакуйте.
2. Дважды щёлкните **Install.bat** и выберите пункт:
   - **1** — пробный запуск: покажет план, ничего не меняет (сделайте его первым);
   - **2** — установка;
   - **3** — установка + Python и pyRevit CLI, если их нет (Routes включатся автоматически);
   - **4** — убрать сервер revitmcp из конфига Claude.

   Windows может показать предупреждение SmartScreen для файла из интернета: **Подробнее → Выполнить в любом случае**. Перед запуском прочитайте скрипт.

   Вместо Install.bat можно запустить из PowerShell в папке со скриптом:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1 -WhatIf   # пробный запуск
   powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1           # установка
   ```

3. Откройте Revit (разрешите загрузку pyRevit), проверьте Routes: **pyRevit → Settings → Routes server**, перезапустите Revit.
4. Полностью закройте Claude Desktop (и значок в области уведомлений) и откройте снова. В **Настройки → Разработчик → Local MCP Servers** у `revitmcp` должен быть статус `running`.
5. Откройте проект в Revit и напишите Claude: `Get Revit project info`.

Все параметры скрипта описаны в начале файла `Install-RevitMCP.ps1` (`Get-Help .\Install-RevitMCP.ps1 -Detailed`).

## Что делает скрипт

1. Проверяет, что Revit закрыт.
2. Скачивает установщик pyRevit 7.0.0 из GitHub Releases, проверяет цифровую подпись и ставит тихо.
3. Клонирует/скачивает RevitMCP в `%APPDATA%\pyRevit\Extensions\RevitMCP.extension`.
4. Находит Python, создаёт окружение `%LOCALAPPDATA%\RevitMCP\venv`, ставит зависимости.
5. Добавляет сервер `revitmcp` в `claude_desktop_config.json` (резервная копия рядом, другие серверы и настройки не трогаются).
6. Пытается включить pyRevit Routes через CLI.

## Откат

Install.bat → пункт **4**, либо:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1 -RemoveClaudeEntry
```

Удалить расширение: папка `%APPDATA%\pyRevit\Extensions\RevitMCP.extension`.

## Безопасность

- Скрипт скачивает код из публичных репозиториев (pyRevit, RevitMCP) и запускает его в вашем Revit. Прочитайте скрипт перед запуском.
- RevitMCP умеет **менять модель** (параметры, спецификации, удаление элементов). Для первого запуска используйте тестовую копию проекта.
- Содержимое модели попадает в чат с Claude.

## Скилл для Claude

В папке `skill/revit-mcp-setup` лежит скилл (`SKILL.md` + скрипт). Он не устанавливает программы сам: это инструкция для Claude. Работает там, где у Claude есть доступ к командной строке этого компьютера (например, Claude Code). Для обычной установки достаточно Install.bat или скрипта.

## Проверено и не проверено

Синтаксис скрипта проверен в PowerShell 7, логика слияния конфига Claude протестирована на тестовых файлах, имена установщиков pyRevit 7.0.0 подтверждены в GitHub Releases. Полный прогон на Windows с Revit не выполнялся. Команда `pyrevit configs routes enable` не проверена: если не сработает, включите Routes вручную (шаг 3).
