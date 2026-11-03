<#
.SYNOPSIS
  Устанавливает pyRevit 7.0.0 и RevitMCP и подключает RevitMCP к Claude Desktop.

.DESCRIPTION
  Что делает скрипт (по порядку):
    1. Проверяет окружение (Windows, Revit закрыт, права).
    2. Скачивает официальный установщик pyRevit из GitHub Releases, проверяет цифровую подпись
       и ставит его тихо (Inno Setup: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART).
    3. Скачивает RevitMCP (oakplank/RevitMCP) в папку RevitMCP.extension корня расширений pyRevit.
    4. Находит Python (3.7-3.13), создаёт виртуальное окружение и ставит requirements.txt.
    5. Добавляет сервер "revitmcp" в claude_desktop_config.json (с резервной копией, остальные
       серверы и настройки не трогаются).
    6. Пытается включить pyRevit Routes через CLI (если не получилось - покажет ручной шаг).

  Скрипт идемпотентен: повторный запуск ничего не ломает. Используйте -WhatIf, чтобы увидеть,
  что будет сделано, без изменений.

.PARAMETER PyRevitVersion   Версия pyRevit. По умолчанию 7.0.0.
.PARAMETER Scope            User (без прав администратора, %APPDATA%) или AllUsers (нужен админ, %PROGRAMDATA%).
.PARAMETER RevitMcpRef      Ветка, тег или коммит RevitMCP. По умолчанию main.
.PARAMETER PythonPath       Полный путь к python.exe (если автоопределение не подходит).
.PARAMETER InstallPython    Если подходящего Python нет, поставить Python 3.13 через winget.
.PARAMETER NoVenv           Не создавать виртуальное окружение: ставить зависимости в выбранный Python.
.PARAMETER InstallCli       Дополнительно поставить pyRevit CLI (нужен, чтобы включить Routes автоматически).
.PARAMETER SkipPyRevit      Пропустить установку pyRevit.
.PARAMETER SkipRevitMcp     Пропустить установку RevitMCP и зависимостей.
.PARAMETER SkipClaudeConfig Не менять конфиг Claude Desktop.
.PARAMETER ClaudeConfigPath Явный путь к claude_desktop_config.json.
.PARAMETER ServerName       Имя сервера в конфиге Claude. По умолчанию revitmcp.
.PARAMETER RemoveClaudeEntry Только убрать сервер из конфига Claude (с резервной копией) и выйти.
.PARAMETER Force            Переустановить даже если уже установлено; пропустить проверку "Revit запущен".

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1 -WhatIf

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Install-RevitMCP.ps1 -Scope AllUsers -InstallPython
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PyRevitVersion = '7.0.0',
    [ValidateSet('User', 'AllUsers')][string]$Scope = 'User',
    [string]$RevitMcpRef = 'main',
    [string]$PythonPath,
    [switch]$InstallPython,
    [switch]$NoVenv,
    [switch]$InstallCli,
    [switch]$SkipPyRevit,
    [switch]$SkipRevitMcp,
    [switch]$SkipClaudeConfig,
    [string]$ClaudeConfigPath,
    [string]$ServerName = 'revitmcp',
    [switch]$RemoveClaudeEntry,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:LogPath = Join-Path $env:TEMP ('revitmcp-install-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
try { Start-Transcript -Path $script:LogPath -Force | Out-Null } catch { }

# ----------------------------------------------------------------------------
# Вывод
# ----------------------------------------------------------------------------
function Write-Step([string]$Text) { Write-Host ''; Write-Host ('== ' + $Text) -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host ('   [OK] ' + $Text) -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host ('   ' + $Text) }
function Write-Warn2([string]$Text) { Write-Host ('   [!] ' + $Text) -ForegroundColor Yellow }

# ----------------------------------------------------------------------------
# Вспомогательные функции
# ----------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-GitHubJson([string]$Url) {
    $headers = @{ 'User-Agent' = 'Install-RevitMCP'; 'Accept' = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = 'Bearer ' + $env:GITHUB_TOKEN }
    return Invoke-RestMethod -Uri $Url -Headers $headers -UseBasicParsing
}

function Save-File([string]$Url, [string]$Dest) {
    Write-Info ('Скачиваю: ' + $Url)
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -Headers @{ 'User-Agent' = 'Install-RevitMCP' } }
    finally { $ProgressPreference = $prev }
}

function Get-InstalledPyRevitVersion {
    $keys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        $items = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match '^pyRevit(\s|$)' -and $_.DisplayName -notmatch 'CLI' }
        foreach ($i in $items) {
            if ($i.PSObject.Properties['DisplayVersion'] -and $i.DisplayVersion) { return [string]$i.DisplayVersion }
        }
    }
    return $null
}

function Test-VersionAtLeast([string]$Have, [string]$Want) {
    try {
        $h = [version]($Have -replace '[^\d\.].*$', '')
        $w = [version]($Want -replace '[^\d\.].*$', '')
        return ($h -ge $w)
    } catch { return $false }
}

# ----------------------------------------------------------------------------
# 1. Проверка окружения
# ----------------------------------------------------------------------------
function Test-Environment {
    Write-Step 'Проверка окружения'
    if ($env:OS -ne 'Windows_NT') { throw 'Скрипт работает только в Windows (Revit существует только для Windows).' }
    Write-Ok ('PowerShell ' + $PSVersionTable.PSVersion)

    $revit = @(Get-Process -Name 'Revit' -ErrorAction SilentlyContinue)
    if ($revit.Count -gt 0 -and -not $Force) {
        throw 'Revit запущен. Закройте Revit (сохраните работу) и запустите скрипт снова. Или добавьте -Force.'
    }
    if ($revit.Count -gt 0) { Write-Warn2 'Revit запущен, но указан -Force: изменения вступят в силу после перезапуска Revit.' }
    else { Write-Ok 'Revit не запущен' }

    $revitDirs = @(Get-ChildItem 'C:\Program Files\Autodesk' -Directory -Filter 'Revit 20*' -ErrorAction SilentlyContinue)
    if ($revitDirs.Count -gt 0) { Write-Ok ('Найден Revit: ' + (($revitDirs | ForEach-Object Name) -join ', ')) }
    else { Write-Warn2 'Папки Autodesk\Revit 20xx не найдено. Убедитесь, что Revit установлен: pyRevit и RevitMCP работают только внутри Revit.' }

    if ($Scope -eq 'AllUsers' -and -not (Test-IsAdmin)) {
        throw 'Режим -Scope AllUsers требует запуска PowerShell от имени администратора.'
    }
}

# ----------------------------------------------------------------------------
# 2. pyRevit
# ----------------------------------------------------------------------------
function Get-PyRevitRelease([string]$Version) {
    $verEsc = [regex]::Escape($Version)
    # Вариант 1: GitHub API
    try {
        $releases = Invoke-GitHubJson 'https://api.github.com/repos/pyrevitlabs/pyRevit/releases?per_page=40'
        $rel = $releases | Where-Object { $_.tag_name -match ('^v' + $verEsc + '(\.|\+|$)') } | Select-Object -First 1
        if ($rel) {
            $assets = @($rel.assets | ForEach-Object { [pscustomobject]@{ name = $_.name; url = $_.browser_download_url } })
            return [pscustomobject]@{ Tag = $rel.tag_name; Name = $rel.name; Assets = $assets }
        }
    } catch {
        Write-Warn2 ('GitHub API недоступен (возможно, лимит запросов): ' + $_.Exception.Message + '. Пробую страницу релизов.')
    }
    # Вариант 2: HTML-страницы GitHub (без лимитов API)
    $html = (Invoke-WebRequest -Uri 'https://github.com/pyrevitlabs/pyRevit/releases' -UseBasicParsing -Headers @{ 'User-Agent' = 'Install-RevitMCP' }).Content
    $m = [regex]::Match($html, 'releases/tag/(v' + $verEsc + '[^"''\s<]*)')
    if (-not $m.Success) { return $null }
    $tag = $m.Groups[1].Value
    $ea = (Invoke-WebRequest -Uri ('https://github.com/pyrevitlabs/pyRevit/releases/expanded_assets/' + $tag) -UseBasicParsing -Headers @{ 'User-Agent' = 'Install-RevitMCP' }).Content
    $assets = New-Object System.Collections.ArrayList
    foreach ($a in [regex]::Matches($ea, 'releases/download/[^/"]+/([^"''\s<]+)')) {
        $name = [uri]::UnescapeDataString($a.Groups[1].Value)
        [void]$assets.Add([pscustomobject]@{ name = $name; url = 'https://github.com/pyrevitlabs/pyRevit/' + $a.Value })
    }
    return [pscustomobject]@{ Tag = [uri]::UnescapeDataString($tag); Name = ('pyRevit ' + $Version); Assets = @($assets) }
}

function Get-InstallerAsset($Release, [string]$Kind) {
    $verEsc = [regex]::Escape($PyRevitVersion)
    $adm = if ($Scope -eq 'AllUsers') { '_admin' } else { '' }
    $prefix = if ($Kind -eq 'Cli') { '^pyRevit_CLI_' } else { '^pyRevit_' }
    $pattern = $prefix + $verEsc + '[\d\.]*' + $adm + '_signed\.exe$'
    $asset = $Release.Assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) {
        $names = ($Release.Assets | ForEach-Object name) -join ', '
        throw ('В релизе нет установщика (' + $Kind + ', ' + $Scope + '). Файлы релиза: ' + $names)
    }
    return $asset
}

function Invoke-InstallerAsset($Asset, [string]$Label) {
    $dest = Join-Path $env:TEMP $Asset.name
    if ($PSCmdlet.ShouldProcess($Asset.url, ('Скачать установщик ' + $Label))) {
        Save-File $Asset.url $dest
        $sig = Get-AuthenticodeSignature -FilePath $dest
        if ($sig.Status -ne 'Valid') {
            if ($Force) { Write-Warn2 ('Подпись установщика: ' + $sig.Status + ' (продолжаю из-за -Force)') }
            else { throw ('Цифровая подпись установщика недействительна: ' + $sig.Status + '. Установка остановлена.') }
        } else {
            Write-Ok ('Подпись действительна: ' + $sig.SignerCertificate.Subject)
        }
    }
    if ($PSCmdlet.ShouldProcess($Asset.name, ('Тихая установка ' + $Label))) {
        Write-Info ('Устанавливаю ' + $Label + ' (это занимает 1-3 минуты)...')
        $p = Start-Process -FilePath $dest -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw ('Установщик ' + $Label + ' завершился с кодом ' + $p.ExitCode + '. Запустите ' + $dest + ' вручную и посмотрите сообщение.') }
        Write-Ok ($Label + ' установлен')
    }
}

function Install-PyRevit {
    Write-Step ('pyRevit ' + $PyRevitVersion)
    $have = Get-InstalledPyRevitVersion
    if ($have) { Write-Info ('Установлена версия: ' + $have) }
    if ($have -and (Test-VersionAtLeast $have $PyRevitVersion) -and -not $Force) {
        Write-Ok 'pyRevit нужной версии уже установлен, пропускаю (используйте -Force для переустановки).'
    } else {
        $rel = Get-PyRevitRelease $PyRevitVersion
        if (-not $rel) { throw ('Релиз pyRevit v' + $PyRevitVersion + ' не найден на GitHub (https://github.com/pyrevitlabs/pyRevit/releases).') }
        Write-Ok ('Релиз: ' + $rel.Name + ' (' + $rel.Tag + ')')
        Invoke-InstallerAsset (Get-InstallerAsset $rel 'App') 'pyRevit'
        $after = Get-InstalledPyRevitVersion
        if ($after) { Write-Ok ('Версия pyRevit в системе: ' + $after) }
    }
}

# ----------------------------------------------------------------------------
# 3. RevitMCP (расширение pyRevit)
# ----------------------------------------------------------------------------
function Get-ExtensionRoot {
    if ($Scope -eq 'AllUsers') { return (Join-Path $env:ProgramData 'pyRevit\Extensions') }
    return (Join-Path $env:APPDATA 'pyRevit\Extensions')
}

function Install-RevitMcpExtension {
    Write-Step 'RevitMCP (расширение pyRevit)'
    $root = Get-ExtensionRoot
    $target = Join-Path $root 'RevitMCP.extension'
    $server = Join-Path $target 'lib\RevitMCP_ExternalServer\server.py'

    if ((Test-Path $server) -and -not $Force) {
        Write-Ok ('RevitMCP уже установлен: ' + $target + ' (используйте -Force для переустановки).')
        return $target
    }

    if ($PSCmdlet.ShouldProcess($target, 'Установить RevitMCP (ref: ' + $RevitMcpRef + ')')) {
        if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        if (Test-Path $target) {
            $bak = $target + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Move-Item -Path $target -Destination $bak -Force
            Write-Info ('Старая версия перенесена в ' + $bak)
        }

        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) {
            Write-Info 'Клонирую репозиторий через git...'
            & $git.Source clone --quiet https://github.com/oakplank/RevitMCP.git $target
            if ($LASTEXITCODE -ne 0) { throw 'git clone завершился с ошибкой.' }
            if ($RevitMcpRef -ne 'main') {
                & $git.Source -C $target checkout --quiet $RevitMcpRef
                if ($LASTEXITCODE -ne 0) { throw ('git checkout ' + $RevitMcpRef + ' завершился с ошибкой.') }
            }
            $sha = (& $git.Source -C $target rev-parse --short HEAD)
        } else {
            Write-Info 'git не найден, скачиваю ZIP...'
            $zip = Join-Path $env:TEMP 'RevitMCP.zip'
            $tmp = Join-Path $env:TEMP ('RevitMCP-extract-' + [guid]::NewGuid().ToString('N'))
            Save-File ('https://codeload.github.com/oakplank/RevitMCP/zip/' + $RevitMcpRef) $zip
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $inner = @(Get-ChildItem $tmp -Directory)
            if ($inner.Count -ne 1) { throw 'Неожиданная структура ZIP-архива RevitMCP.' }
            Move-Item -Path $inner[0].FullName -Destination $target -Force
            Remove-Item $tmp, $zip -Recurse -Force -ErrorAction SilentlyContinue
            $sha = $RevitMcpRef
        }

        if (-not (Test-Path $server)) { throw ('Не найден server.py по пути ' + $server + '. Структура репозитория могла измениться.') }
        Write-Ok ('RevitMCP установлен: ' + $target + ' (' + $sha + ')')
    }
    return $target
}

# ----------------------------------------------------------------------------
# 4. Python и зависимости
# ----------------------------------------------------------------------------
function Get-PythonVersionText([string]$Exe) {
    try {
        $v = & $Exe -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { return ([string]$v).Trim() }
    } catch { }
    return $null
}

function Test-PythonSuitable([string]$Exe) {
    $v = Get-PythonVersionText $Exe
    if (-not $v) { return $false }
    $parts = $v.Split('.')
    $major = [int]$parts[0]; $minor = [int]$parts[1]
    return ($major -eq 3 -and $minor -ge 7 -and $minor -le 13)
}

function Find-Python {
    if ($PythonPath) {
        if (-not (Test-Path $PythonPath)) { throw ('Указанный python.exe не найден: ' + $PythonPath) }
        if (-not (Test-PythonSuitable $PythonPath)) { throw ('Нужен Python 3.7-3.13, а указанный: ' + (Get-PythonVersionText $PythonPath)) }
        return (Resolve-Path $PythonPath).Path
    }
    $candidates = New-Object System.Collections.ArrayList
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        foreach ($ver in '3.13', '3.12', '3.11', '3.10', '3.9') {
            try {
                $exe = & $py.Source ('-' + $ver) -c 'import sys; print(sys.executable)' 2>$null
                if ($LASTEXITCODE -eq 0 -and $exe) { [void]$candidates.Add(([string]$exe).Trim()) }
            } catch { }
        }
    }
    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyCmd) { [void]$candidates.Add($pyCmd.Source) }
    foreach ($c in $candidates) {
        # Заглушка Microsoft Store (WindowsApps\python.exe) не подходит
        if ($c -like '*\WindowsApps\*') { continue }
        if (Test-PythonSuitable $c) { return $c }
    }
    return $null
}

function Install-PythonViaWinget {
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wg) { throw 'winget не найден. Установите Python 3.13 с python.org и запустите скрипт снова (или укажите -PythonPath).' }
    if ($PSCmdlet.ShouldProcess('Python.Python.3.13', 'Установить через winget')) {
        & $wg.Source install --id Python.Python.3.13 --exact --scope user --silent --accept-package-agreements --accept-source-agreements
        # Обновить PATH текущего процесса
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }
}

function Install-Dependencies([string]$ExtensionDir) {
    Write-Step 'Python и зависимости RevitMCP'
    $python = Find-Python
    if (-not $python -and $InstallPython) {
        Write-Info 'Подходящий Python не найден, ставлю Python 3.13 через winget...'
        Install-PythonViaWinget
        $python = Find-Python
        if (-not $python) {
            $guess = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'
            if (Test-Path $guess) { $python = $guess }
        }
    }
    if (-not $python) {
        throw 'Не найден Python 3.7-3.13 (рекомендуется 3.13 или старше; 3.14 даёт предупреждения зависимостей). Запустите скрипт с -InstallPython или укажите -PythonPath.'
    }
    Write-Ok ('Python ' + (Get-PythonVersionText $python) + ': ' + $python)

    $req = Join-Path $ExtensionDir 'requirements.txt'
    if (-not (Test-Path $req)) { throw ('Не найден requirements.txt: ' + $req) }

    $runPython = $python
    if (-not $NoVenv) {
        $venv = Join-Path $env:LOCALAPPDATA 'RevitMCP\venv'
        $venvPy = Join-Path $venv 'Scripts\python.exe'
        if (-not (Test-Path $venvPy)) {
            if ($PSCmdlet.ShouldProcess($venv, 'Создать виртуальное окружение')) {
                Write-Info ('Создаю виртуальное окружение: ' + $venv)
                & $python -m venv $venv
                if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать виртуальное окружение (python -m venv).' }
            }
        } else { Write-Info ('Использую существующее окружение: ' + $venv) }
        if (Test-Path $venvPy) { $runPython = $venvPy }
    }

    if ($PSCmdlet.ShouldProcess($runPython, 'pip install -r requirements.txt')) {
        Write-Info 'Устанавливаю зависимости (первый раз 1-3 минуты)...'
        & $runPython -m pip install --disable-pip-version-check --quiet --upgrade pip
        & $runPython -m pip install --disable-pip-version-check --quiet -r $req
        if ($LASTEXITCODE -ne 0) { throw 'pip install завершился с ошибкой. Запустите вручную: ' + $runPython + ' -m pip install -r ' + $req }
        & $runPython -c 'import mcp, flask' 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Зависимости установлены, но import mcp, flask не проходит.' }
        Write-Ok 'Зависимости установлены (mcp, flask и др.)'
    }
    return $runPython
}

# ----------------------------------------------------------------------------
# 5. Конфиг Claude Desktop
# ----------------------------------------------------------------------------
function Get-ClaudeConfigPath {
    if ($ClaudeConfigPath) { return $ClaudeConfigPath }
    # Версия из Microsoft Store (MSIX) хранит конфиг в виртуализированной папке пакета
    $pkgRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path $pkgRoot) {
        $pkgs = @(Get-ChildItem $pkgRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue)
        foreach ($p in $pkgs) {
            $dir = Join-Path $p.FullName 'LocalCache\Roaming\Claude'
            if (Test-Path $dir) { return (Join-Path $dir 'claude_desktop_config.json') }
        }
    }
    return (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json')
}

function Read-ClaudeConfig([string]$Path) {
    if (-not (Test-Path $Path)) { return [pscustomobject]@{} }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{} }
    try { return ($raw | ConvertFrom-Json) }
    catch { throw ('Файл конфига Claude не является корректным JSON, я его не трогаю: ' + $Path + '. Исправьте файл или удалите, затем запустите скрипт снова. Ошибка: ' + $_.Exception.Message) }
}

function Set-RevitMcpEntry($Config, [string]$Name, [string]$PythonExe, [string]$ServerPy) {
    if (-not $Config.PSObject.Properties['mcpServers']) {
        $Config | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $entry = [pscustomobject]@{ command = $PythonExe; args = @($ServerPy, '--surface', 'mcp') }
    $Config.mcpServers | Add-Member -NotePropertyName $Name -NotePropertyValue $entry -Force
    return $Config
}

function Remove-RevitMcpEntry($Config, [string]$Name) {
    if ($Config.PSObject.Properties['mcpServers'] -and $Config.mcpServers.PSObject.Properties[$Name]) {
        $Config.mcpServers.PSObject.Properties.Remove($Name)
        return $true
    }
    return $false
}

function Write-ClaudeConfig([string]$Path, $Config) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path $Path) {
        $bak = $Path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -Path $Path -Destination $bak -Force
        Write-Info ('Резервная копия: ' + $bak)
    }
    $json = ConvertTo-Json -InputObject $Config -Depth 20
    # Проверяем, что получившийся JSON читается обратно
    [void]($json | ConvertFrom-Json)
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Update-ClaudeConfig([string]$PythonExe, [string]$ServerPy) {
    Write-Step 'Конфиг Claude Desktop'
    $path = Get-ClaudeConfigPath
    Write-Info ('Файл: ' + $path)
    $cfg = Read-ClaudeConfig $path
    $cfg = Set-RevitMcpEntry $cfg $ServerName $PythonExe $ServerPy
    if ($PSCmdlet.ShouldProcess($path, ('Добавить сервер ' + $ServerName + ' в конфиг Claude Desktop'))) {
        Write-ClaudeConfig $path $cfg
        Write-Ok ('Сервер "' + $ServerName + '" добавлен. Остальные серверы и настройки сохранены.')
        Write-Info ('command: ' + $PythonExe)
        Write-Info ('server.py: ' + $ServerPy)
    }
}

# ----------------------------------------------------------------------------
# 6. pyRevit Routes (попытка через CLI)
# ----------------------------------------------------------------------------
function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Enable-PyRevitRoutes {
    Write-Step 'pyRevit Routes'
    $manual = 'Включите Routes вручную: Revit > вкладка pyRevit > Settings > Routes server > включить, затем перезапустить Revit.'
    $cli = Get-Command pyrevit -ErrorAction SilentlyContinue
    if (-not $cli -and $InstallCli) {
        $rel = Get-PyRevitRelease $PyRevitVersion
        if ($rel) {
            Invoke-InstallerAsset (Get-InstallerAsset $rel 'Cli') 'pyRevit CLI'
            Update-SessionPath
            $cli = Get-Command pyrevit -ErrorAction SilentlyContinue
        }
    }
    if (-not $cli) {
        Write-Warn2 ('Команда pyrevit (CLI) не найдена. ' + $manual + ' (Или запустите скрипт с -InstallCli.)')
        return
    }
    if ($PSCmdlet.ShouldProcess('pyrevit configs routes enable', 'Включить Routes server')) {
        try {
            & $cli.Source configs routes enable 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok 'Routes server включён через CLI. Перезапустите Revit.' }
            else { Write-Warn2 ('CLI не смог включить Routes. ' + $manual) }
        } catch {
            Write-Warn2 ('CLI не смог включить Routes. ' + $manual)
        }
    }
}

# ----------------------------------------------------------------------------
# Основной сценарий
# ----------------------------------------------------------------------------
try {
    if ($RemoveClaudeEntry) {
        Write-Step 'Удаление сервера из конфига Claude'
        $path = Get-ClaudeConfigPath
        $cfg = Read-ClaudeConfig $path
        if (Remove-RevitMcpEntry $cfg $ServerName) {
            if ($PSCmdlet.ShouldProcess($path, ('Удалить сервер ' + $ServerName))) {
                Write-ClaudeConfig $path $cfg
                Write-Ok ('Сервер "' + $ServerName + '" удалён. Перезапустите Claude Desktop.')
            }
        } else { Write-Info ('Сервер "' + $ServerName + '" в конфиге не найден.') }
        return
    }

    Test-Environment

    if (-not $SkipPyRevit) { Install-PyRevit } else { Write-Info 'Установка pyRevit пропущена (-SkipPyRevit).' }

    $extDir = $null
    $pythonExe = $null
    if (-not $SkipRevitMcp) {
        $extDir = Install-RevitMcpExtension
        if ($extDir -and (Test-Path (Join-Path $extDir 'requirements.txt'))) {
            $pythonExe = Install-Dependencies $extDir
        } elseif ($WhatIfPreference) {
            Write-Info '(WhatIf) зависимости будут поставлены после установки расширения.'
        }
    } else {
        Write-Info 'Установка RevitMCP пропущена (-SkipRevitMcp).'
        $extDir = Join-Path (Get-ExtensionRoot) 'RevitMCP.extension'
    }

    if (-not $SkipClaudeConfig) {
        $serverPy = Join-Path $extDir 'lib\RevitMCP_ExternalServer\server.py'
        if (-not $pythonExe) { $pythonExe = Find-Python }
        if (-not $pythonExe) { $pythonExe = 'python'; Write-Warn2 'Python не определён, в конфиг записано просто "python". Лучше указать полный путь (-PythonPath).' }
        if ((Test-Path $serverPy) -or $WhatIfPreference) { Update-ClaudeConfig $pythonExe $serverPy }
        else { Write-Warn2 ('server.py не найден (' + $serverPy + '), конфиг Claude не изменён.') }
    } else {
        Write-Info 'Изменение конфига Claude пропущено (-SkipClaudeConfig).'
    }

    if (-not $SkipPyRevit) { Enable-PyRevitRoutes }

    Write-Step 'Готово. Что осталось сделать вручную'
    Write-Info '1. Откройте Revit и согласитесь загрузить pyRevit, если появится запрос безопасности (Always Load).'
    Write-Info '2. Если Routes не включился автоматически: Revit > pyRevit > Settings > Routes server > включить, затем перезапустить Revit.'
    Write-Info '3. Полностью закройте Claude Desktop (в том числе значок в области уведомлений) и откройте снова.'
    Write-Info '4. Откройте проект в Revit. В Claude: Настройки > Разработчик > Local MCP Servers: revitmcp должен быть "running".'
    Write-Info '5. Проверка: напишите Claude "Get Revit project info".'
    Write-Info ('Лог установки: ' + $script:LogPath)
}
catch {
    Write-Host ''
    Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('Лог: ' + $script:LogPath) -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
try { Stop-Transcript | Out-Null } catch { }
