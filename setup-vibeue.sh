#!/usr/bin/env bash
# One-shot VibeUE + MCP bootstrap for an Unreal 5.8 / 5.7 project.
#   setup-vibeue.sh [Project.uproject] [--agent ClaudeCode|Cursor|VSCode|Gemini|Codex|All]
#                   [--port N] [--engine DIR] [--api-key KEY] [--no-gui] [--no-build]
# Re-runnable: every file edit is an upsert, the plugin clone and the initial commit are skipped when present.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
win=0; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) win=1 ;; esac
upath() { if [ $win = 1 ] && [ -n "$1" ]; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
wpath() { if [ $win = 1 ]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

agent= port= engine="${UE_ENGINE_PATH:-}" apikey= gui=$win build=1 uproject=
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) agent="$2"; shift ;;
    --port) port="$2"; shift ;;
    --engine) engine="$2"; shift ;;
    --api-key) apikey="$2"; shift ;;
    --no-gui) gui=0 ;;
    --no-build) build=0 ;;
    *.uproject) uproject="$(upath "$1")" ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# 1. Project
here="$(cd "$(dirname "$(upath "$0")")" && pwd)"
if [ -z "$uproject" ]; then
  for f in "$here"/*.uproject; do [ -f "$f" ] && { uproject="$f"; break; }; done
fi
[ -n "$uproject" ] && [ -f "$uproject" ] || die "no .uproject next to $here (pass one as an argument)"
proj="$(cd "$(dirname "$uproject")" && pwd)"
uproject="$proj/$(basename "$uproject")"
name="$(basename "$uproject" .uproject)"
cd "$proj"
# Same rule as Epic's new-project wizard (GameProjectUtils.cpp); a bad name breaks UBT's generated .Target.cs.
[[ "$name" =~ ^[[:alpha:]][[:alnum:]_]*$ ]] || die "'$name' is not a valid Unreal project name: start with a letter, then only letters, digits or _ (no spaces). Rename the .uproject."
[ ${#name} -le 20 ] || echo "WARNING: Unreal recommends project names of at most 20 characters ('$name' has ${#name})."

# 2. Engine: --engine / $UE_ENGINE_PATH -> HKCU Builds -> HKLM -> Epic launcher manifest
assoc="$(sed -n 's/.*"EngineAssociation"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$uproject" | head -1)"
regval() { MSYS_NO_PATHCONV=1 reg query "$1" /v "$2" 2>/dev/null | sed -n 's/.*REG_SZ[[:space:]]*//p' | tr -d '\r' | head -1 || true; }
if [ -z "$engine" ] && [ $win = 1 ]; then
  engine="$(regval 'HKCU\Software\Epic Games\Unreal Engine\Builds' "$assoc")"
  [ -n "$engine" ] || engine="$(regval "HKLM\\SOFTWARE\\EpicGames\\Unreal Engine\\$assoc" InstalledDirectory)"
  dat="$(upath "${PROGRAMDATA:-C:\\ProgramData}")/Epic/UnrealEngineLauncher/LauncherInstalled.dat"
  if [ -z "$engine" ] && [ -f "$dat" ]; then
    engine="$(awk -v app="\"AppName\": \"UE_$assoc\"" '/"InstallLocation"/ {loc=$0} index($0, app) {print loc; exit}' "$dat" \
      | sed 's/.*"InstallLocation": *"//; s/",*[[:space:]]*$//; s/\\\\/\\/g')"
  fi
fi
engine="$(upath "$engine")"
engine_version() { grep -oE '"(Major|Minor)Version": *[0-9]+' "$1/Engine/Build/Build.version" | grep -oE '[0-9]+$' | paste -sd. -; }

guess="$assoc"; [ -f "$engine/Engine/Build/Build.version" ] && guess="$(engine_version "$engine")"
if [ "$guess" = 5.7 ]; then defport=8088; showkey=1; else defport=8000; showkey=0; fi
# Keys can't be created programmatically (vibeue.com is Google sign-in only): open the page, the user pastes the key.
if [ $showkey = 1 ] && [ -z "$apikey" ] && [ $win = 1 ] && { [ $gui = 1 ] || [ -t 0 ]; }; then
  echo "Opening https://www.vibeue.com/login -- sign in, copy your free VibeUE API key and paste it into the setup."
  powershell -NoProfile -Command "Start-Process 'https://www.vibeue.com/login'" || true
fi

# 3. Values: WinForms dialog, or prompts for anything not passed on the command line
if [ $gui = 1 ]; then
  ps1="$(mktemp -t vibeue-XXXX).ps1"
  cat > "$ps1" <<'PS'
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object Windows.Forms.Form -Property @{ Text = 'VibeUE setup'; Width = 520; StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false }
$script:y = 15
function Row($label, $ctl) {
  $l = New-Object Windows.Forms.Label -Property @{ Text = $label; Left = 10; Top = $script:y + 3; Width = 110 }
  $ctl.Left = 125; $ctl.Top = $script:y; $ctl.Width = 365
  $f.Controls.AddRange(@($l, $ctl)); $script:y += 35
}
$a = New-Object Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList' }
$a.Items.AddRange(@('ClaudeCode', 'Cursor', 'VSCode', 'Gemini', 'Codex', 'All')); $a.SelectedItem = $env:VUE_AGENT
Row 'Agent' $a
$p = New-Object Windows.Forms.TextBox -Property @{ Text = $env:VUE_PORT }; Row 'Port' $p
$e = New-Object Windows.Forms.TextBox -Property @{ Text = $env:VUE_ENGINE }; Row 'Engine path' $e
$k = New-Object Windows.Forms.TextBox -Property @{ Text = $env:VUE_APIKEY }
if ($env:VUE_SHOWKEY -eq '1') { Row 'VibeUE API key' $k }
$ok = New-Object Windows.Forms.Button -Property @{ Text = 'OK'; DialogResult = 'OK'; Left = 330; Top = $script:y + 5 }
$no = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel'; DialogResult = 'Cancel'; Left = 415; Top = $script:y + 5 }
$f.AcceptButton = $ok; $f.CancelButton = $no; $f.Controls.AddRange(@($ok, $no)); $f.Height = $script:y + 85
if ($f.ShowDialog() -ne 'OK') { exit 1 }
"AGENT=$($a.SelectedItem)"; "PORT=$($p.Text)"; "ENGINE=$($e.Text)"; "APIKEY=$($k.Text)"
PS
  out="$(VUE_AGENT="${agent:-ClaudeCode}" VUE_PORT="${port:-$defport}" VUE_ENGINE="$( [ -n "$engine" ] && wpath "$engine")" \
    VUE_APIKEY="$apikey" VUE_SHOWKEY=$showkey powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$(wpath "$ps1")")" \
    || { rm -f "$ps1"; die "cancelled"; }
  rm -f "$ps1"
  while IFS='=' read -r k v; do
    v="${v%$'\r'}"
    case "$k" in AGENT) agent="$v" ;; PORT) port="$v" ;; ENGINE) engine="$(upath "$v")" ;; APIKEY) apikey="$v" ;; esac
  done <<< "$out"
else
  ask() { # ask VAR label default -- keeps a value passed as a flag, takes the default when stdin isn't a terminal
    local v=
    [ -n "${!1}" ] && return
    [ -t 0 ] && read -rp "$2 [$3]: " v
    printf -v "$1" '%s' "${v:-$3}"
  }
  ask agent "Agent (ClaudeCode|Cursor|VSCode|Gemini|Codex|All)" ClaudeCode
  ask port "Port" "$defport"
  ask engine "Engine path" "$engine"; engine="$(upath "$engine")"
  [ $showkey = 1 ] && ask apikey "VibeUE API key (required on 5.7 for tool execution)" ""
fi

case "$agent" in ClaudeCode|Cursor|VSCode|Gemini|Codex|All) ;; *) die "unknown agent '$agent'" ;; esac
[[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "bad port '$port'"
[ -n "$engine" ] || die "could not find Unreal Engine $assoc (checked the registry and the Epic launcher); pass --engine DIR or set UE_ENGINE_PATH"
[ -f "$engine/Engine/Build/Build.version" ] || die "'$engine' is not an Unreal Engine install (no Engine/Build/Build.version)"
ver="$(engine_version "$engine")"
case "$ver" in 5.8) branch=5-8 ;; 5.7) branch=5-7 ;; *) die "engine $ver is not supported (need 5.7 or 5.8)" ;; esac
[ "$ver" = "$assoc" ] || echo "WARNING: $name.uproject is associated with '$assoc' but the engine is $ver"
[ "$ver" = 5.7 ] && [ -z "$apikey" ] && echo "WARNING: no VibeUE API key — 5.7 tool execution needs one (Project Settings > Plugins > VibeUE)"

# VibeUE ships no binaries, so building needs MSVC (VS 2022 17.8+ / VS 2026, Community or Build Tools).
# Checked before any long-running step so a fresh PC finds out (and can install) up front.
msvc() { "$(cygpath -F 42)/Microsoft Visual Studio/Installer/vswhere.exe" -products '*' -version '[17.8,)' \
  -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>/dev/null | head -1 || true; }
if [ $build = 1 ] && [ $win = 1 ] && [ -z "$(msvc)" ]; then
  echo "Visual Studio C++ build tools (VS 2022 17.8+) were not found; they are needed to compile VibeUE."
  ans=n
  if [ -t 0 ] && command -v winget >/dev/null; then
    read -rp "Install Visual Studio 2022 Build Tools now with winget (several GB, asks for admin)? [y/N] " ans
  fi
  if [[ "$ans" == [yY]* ]]; then
    winget install -e --id Microsoft.VisualStudio.2022.BuildTools --source winget --accept-package-agreements --accept-source-agreements \
      --override "--passive --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.Net.Component.4.6.2.TargetingPack" || true
  fi
  [ -n "$(msvc)" ] || die "no C++ toolchain. Install Visual Studio 2022 with 'Game development with C++' (https://visualstudio.microsoft.com/downloads/) and re-run, or pass --no-build."
fi

py="$engine/Engine/Binaries/ThirdParty/Python3/Win64/python.exe"
[ -f "$py" ] || py=python3

# 4. Plugin
plugin=
for f in Plugins/*/VibeUE.uplugin; do [ -f "$f" ] && plugin="$(dirname "$f")"; done
if [ -z "$plugin" ]; then
  plugin=Plugins/VibeUE
  git clone --depth 1 -b "$branch" https://github.com/kevinpbuckley/VibeUE.git "$plugin"
else
  echo "VibeUE already present: $plugin"
fi

# 5-9. File edits (.uproject, ini, MCP client configs, agent guide, .gitignore)
changed="$(VUE_PROJ="$(wpath "$proj")" VUE_UPROJECT="$name.uproject" VUE_VER="$ver" VUE_AGENT="$agent" \
  VUE_PORT="$port" VUE_APIKEY="$apikey" VUE_PLUGIN="$plugin" "$py" - <<'PY'
import json, os, re, shutil, sys

E = os.environ
proj, ver, agent, plugin = E['VUE_PROJ'], E['VUE_VER'], E['VUE_AGENT'], E['VUE_PLUGIN']
url = f"http://127.0.0.1:{E['VUE_PORT']}/mcp"
SERVER = 'unreal-mcp'
changed = []

def read(rel):
    try:
        with open(os.path.join(proj, rel), encoding='utf-8-sig', newline='') as f:
            return f.read()
    except FileNotFoundError:
        return None

def write(rel, text):
    if read(rel) == text:
        return
    path = os.path.join(proj, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(text)
    changed.append(rel)

def json_edit(rel, fn, indent='\t'):
    try:
        old = json.loads(read(rel) or '{}')
    except ValueError:
        old = {}  # malformed: overwrite, same as ModelContextProtocolClientConfig.cpp
    new = json.loads(json.dumps(old))
    fn(new)
    if new != old or read(rel) is None:  # untouched files keep their formatting
        write(rel, json.dumps(new, indent=indent) + '\n')

def ini_upsert(rel, section, kv):
    text = read(rel) or ''
    nl = '\r\n' if '\r\n' in text else '\n'  # keep the editor's CRLF so re-runs stay byte-identical
    lines = text.splitlines()
    hdr = f'[{section}]'
    if hdr not in (l.strip() for l in lines):
        if lines and lines[-1].strip():
            lines.append('')
        lines.append(hdr)
    start = [l.strip() for l in lines].index(hdr) + 1
    end = start
    while end < len(lines) and not lines[end].lstrip().startswith('['):
        end += 1
    while end > start and not lines[end - 1].strip():
        end -= 1
    for k, v in kv.items():
        if isinstance(v, list):  # UE array: repeated plain keys. Saved/ inis ignore +/! prefixes (verified headless).
            keep = [l for l in lines[start:end] if l.split('=', 1)[0].strip().lstrip('+-.!') != k]
            lines[start:end] = keep + [f'{k}={x}' for x in v]
            end = start + len(keep) + len(v)
            continue
        for n in range(start, end):
            if lines[n].split('=', 1)[0].strip() == k:
                lines[n] = f'{k}={v}'
                break
        else:
            lines.insert(end, f'{k}={v}')
            end += 1
    write(rel, nl.join(lines) + nl)

# 5. .uproject plugins (VibeUE.uplugin declares the rest; 5.7 needs none)
def enable_plugins(d):
    plugins = d.setdefault('Plugins', [])
    for name in ('ModelContextProtocol', 'AllToolsets', 'EditorToolset', 'Terminal'):
        entry = next((p for p in plugins if p.get('Name') == name), None)
        if entry:
            entry['Enabled'] = True
        else:
            plugins.append({'Name': name, 'Enabled': True})
if ver == '5.8':
    json_edit(E['VUE_UPROJECT'], enable_plugins)

# 6. MCP server settings
INI = 'Config/DefaultEditorPerProjectUserSettings.ini'
if ver == '5.8':
    ini_upsert(INI, '/Script/ModelContextProtocolEngine.ModelContextProtocolSettings', {
        'ServerUrlPath': '/mcp', 'ServerPortNumber': E['VUE_PORT'], 'bAutoStartServer': 'True', 'bEnableToolSearch': 'True'})
else:
    ini_upsert(INI, 'VibeUE.MCPServer', {'Enabled': 'True', 'Port': E['VUE_PORT']})
    if E['VUE_APIKEY']:  # Saved/ (git-ignored, read via GEditorPerProjectIni) so the key never gets committed
        ini_upsert('Saved/Config/WindowsEditor/EditorPerProjectUserSettings.ini', 'VibeUE', {'VibeUEApiKey': E['VUE_APIKEY']})

# 6b. In-editor Terminal panel, per Epic's "Unreal MCP in Unreal Editor" recipe: capable TERM, cd to the
# project (installed builds open the panel in the engine dir), then the agent CLI. Saved/ (per-machine,
# git-ignored) because the path is absolute -- it is where Editor Preferences would store it too.
if ver == '5.8' and os.name == 'nt':
    commands = ['set TERM=xterm-256color', 'cd /d "%s"' % proj.replace('\\', '/')]
    cli = {'ClaudeCode': 'claude', 'All': 'claude', 'Gemini': 'gemini', 'Codex': 'codex'}.get(agent)
    if cli:
        commands.append(cli)
        if not shutil.which(cli):
            print(f"NOTE: '{cli}' is not on PATH yet; the in-editor Terminal runs it on open, so install it first.", file=sys.stderr)
    ini_upsert('Saved/Config/WindowsEditor/EditorPerProjectUserSettings.ini', '/Script/Terminal.TerminalSettings',
               {'StartupCommands': commands})

# 7. MCP client configs (shapes from ModelContextProtocolClientConfig.cpp) + 8. guide targets (VibeUE Module.cpp)
AGENTS = {
    'ClaudeCode': ('.mcp.json', 'mcpServers', {'type': 'http', 'url': url}, 'CLAUDE.md'),
    'Cursor': ('.cursor/mcp.json', 'mcpServers', {'url': url}, 'AGENTS.md'),
    'VSCode': ('.vscode/mcp.json', 'servers', {'type': 'http', 'url': url}, 'AGENTS.md'),
    'Gemini': ('.gemini/settings.json', 'mcpServers', {'httpUrl': url}, 'GEMINI.md'),
    'Codex': ('.codex/config.toml', None, None, 'AGENTS.md'),
}
chosen = list(AGENTS) if agent == 'All' else [agent]
for a in chosen:
    rel, key, entry, _ = AGENTS[a]
    if key:
        json_edit(rel, lambda d: d.setdefault(key, {}).__setitem__(SERVER, entry))
    elif read(rel) is None:
        write(rel, f'[mcp_servers.{SERVER}]\nurl = "{url}"\n')
    elif f'[mcp_servers.{SERVER}]' not in read(rel):
        print(f'WARNING: {rel} exists; add [mcp_servers.{SERVER}] url = "{url}" by hand', file=sys.stderr)

if 'ClaudeCode' in chosen:
    def claude_local(d):
        d['enableAllProjectMcpServers'] = True
        servers = d.setdefault('enabledMcpjsonServers', [])
        if SERVER not in servers:
            servers.append(SERVER)
    json_edit('.claude/settings.local.json', claude_local, indent=2)

# 8. Agent guide, in the same marker block VibeUE.GenerateAgentConfig refreshes
with open(os.path.join(proj, plugin, 'Content/samples/AGENTS.md.sample'), encoding='utf-8-sig', newline='') as f:
    sample = f.read()
with open(os.path.join(proj, plugin, 'VibeUE.uplugin'), encoding='utf-8-sig') as f:
    version = re.search(r'"VersionName"\s*:\s*"([^"]*)"', f.read()).group(1)
END = '<!-- END VibeUE -->'
block = (f'<!-- BEGIN VibeUE (v{version}) \u2014 generated by VibeUE.GenerateAgentConfig; re-run to refresh -->\n'
         + sample + ('' if sample.endswith('\n') else '\n') + END + '\n')
for rel in dict.fromkeys(AGENTS[a][3] for a in chosen):
    old = read(rel)
    if old is None:
        new = block
    else:
        b = old.lower().find('<!-- begin vibeue')
        if b < 0:
            new = old + ('' if old.endswith('\n') else '\n') + '\n' + block
        else:
            e = old.lower().find(END.lower(), b)
            new = old[:b] + block + ('' if e < 0 else old[e + len(END):].removeprefix('\n'))
    write(rel, new)

# 9. .gitignore (UE generated folders + the upstream plugin clone)
IGNORE = ['Binaries/', 'Build/', 'DerivedDataCache/', 'Intermediate/', 'Saved/', '.vs/', '*.VC.db', '*.opensdf',
          '*.opendb', '*.sdf', '*.sln', '*.suo', '*.xcodeproj', '*.xcworkspace', f'/{plugin}/']
old = read('.gitignore') or ''
have = {l.strip() for l in old.splitlines()}
missing = [l for l in IGNORE if l not in have]
if missing:
    write('.gitignore', old + ('\n' if old and not old.endswith('\n') else '') + '\n'.join(missing) + '\n')

print('\n'.join(changed))
PY
)"

# 9. Git -- non-fatal: e.g. "dubious ownership" on exFAT/copied folders must not block the build
{
  [ -e .git ] || git init -q
  if ! git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    if git config user.name >/dev/null && git config user.email >/dev/null; then
      git add -A && git commit -qm "Initial commit: VibeUE + MCP setup" && echo "Created initial commit."
    else
      echo "NOTE: git user.name/user.email not set; skipped the initial commit."
    fi
  fi
} || echo "NOTE: git step failed (see above); continuing."

echo
echo "Project : $uproject"
echo "Engine  : $engine ($ver)"
echo "Agent   : $agent"
echo "MCP url : http://127.0.0.1:$port/mcp"
echo "Changed : ${changed:-(nothing)}" | sed '2,$s/^/          /'

# 10-11. Build + launch
if [ $build = 0 ]; then
  echo "Skipped build + launch (--no-build)."
elif [ $win = 0 ]; then
  echo "Build/launch here is Windows-only; use $plugin/BuildAndLaunchGame.sh --engine \"$engine\"."
else
  if [ -d Source ]; then target="${name}Editor" projarg="$(wpath "$uproject")"
  else target=UnrealEditor projarg="-Project=$(wpath "$uproject")"; fi
  # Via PowerShell: Git Bash cannot run a .bat whose path has spaces (default C:\Program Files\Epic Games\...).
  VUE_BAT="$(wpath "$engine/Engine/Build/BatchFiles/Build.bat")" VUE_TARGET="$target" VUE_PROJARG="$projarg" \
    powershell -NoProfile -ExecutionPolicy Bypass -Command '& $env:VUE_BAT $env:VUE_TARGET Win64 Development $env:VUE_PROJARG -waitmutex; exit $LASTEXITCODE' \
    || die "build failed (close any editor running this project, then re-run); UBT log: $(wpath "${LOCALAPPDATA:-}")\\UnrealBuildTool\\Log.txt"
  # Start-Process: detached from this console, so closing the window doesn't take the editor with it.
  VUE_EXE="$(wpath "$engine/Engine/Binaries/Win64/UnrealEditor.exe")" VUE_UPROJECT="$(wpath "$uproject")" \
    powershell -NoProfile -Command 'Start-Process -FilePath $env:VUE_EXE -ArgumentList ([char]34 + $env:VUE_UPROJECT + [char]34)'
  echo "Editor launching; ready when Saved/VibeUE/Signals/editor-<pid>-true.json appears."
fi
