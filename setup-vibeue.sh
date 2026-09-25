#!/usr/bin/env bash
# One-shot VibeUE + MCP bootstrap for an Unreal 5.8 / 5.7 project.
#   setup-vibeue.sh [Project.uproject] [--agent ClaudeCode|Cursor|VSCode|Gemini|Codex|All]
#                   [--port N] [--engine DIR] [--api-key KEY] [--no-gui] [--no-build] [--internal|--external]
# Where the agent runs (asked during setup unless passed):
#   --internal: in the editor's Terminal panel (Terminal plugin + startup commands).
#   --external: no in-editor Terminal; writes Start-<Project>.cmd (editor + agent in its own PowerShell window, which outlives the editor)
#               plus a Start-<Project> shortcut to it wearing the .uproject icon recolored Unreal purple.
# Re-runnable: every file edit is an upsert, the plugin clone and the initial commit are skipped when present.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
win=0; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) win=1 ;; esac
upath() { if [ $win = 1 ] && [ -n "$1" ]; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
wpath() { if [ $win = 1 ]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

agent= port= engine="${UE_ENGINE_PATH:-}" apikey= gui=$win build=1 mode= uproject=
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) agent="$2"; shift ;;
    --port) port="$2"; shift ;;
    --engine) engine="$2"; shift ;;
    --api-key) apikey="$2"; shift ;;
    --no-gui) gui=0 ;;
    --no-build) build=0 ;;
    --internal) mode=inside ;;
    --external) mode=outside ;;
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
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
# Unreal Editor dark theme; accent = Unreal purple. ASCII only: powershell 5.1 reads this file as ANSI.
$accent = '#A139BF'; $accentText = '#C27ED5'
$name = $env:VUE_NAME; $ver = $env:VUE_VER; $showKey = $env:VUE_SHOWKEY -eq '1'; $build = $env:VUE_BUILD -ne '0'
$script:mode = if ($env:VUE_MODE -eq 'outside') { 'outside' } else { 'inside' }
$script:cli = 'PS>'
function C($h) { [Drawing.ColorTranslator]::FromHtml($h) }
function B($h) { New-Object Drawing.SolidBrush (C $h) }
function P($h, $w = 1) { New-Object Drawing.Pen (C $h), $w }
function F($size, $style = 'Regular', $face = 'Segoe UI') { New-Object Drawing.Font $face, $size, ([Drawing.FontStyle]$style) }
function Pts([float[]]$xy) { for ($i = 0; $i -lt $xy.Count; $i += 2) { New-Object Drawing.PointF $xy[$i], $xy[$i + 1] } }
function Add($parent, $type, $x, $y, $w, $h, $props = @{}) {
  $c = New-Object "Windows.Forms.$type" -Property $props
  $c.SetBounds($x, $y, $w, $h); $parent.Controls.Add($c); $c
}
function Lbl($parent, $text, $x, $y, $w, $h, $color = '#A0A0A0', $font = (F 9)) {
  Add $parent Label $x $y $w $h @{ Text = $text; ForeColor = (C $color); Font = $font; BackColor = [Drawing.Color]::Transparent }
}
function Field($box) { $box.BackColor = C '#0F0F0F'; $box.ForeColor = C '#C0C0C0'; $box.BorderStyle = 'FixedSingle'; $box.Font = F 11 Regular Consolas; $box }
function Btn($btn, $bg, $border) { $btn.FlatStyle = 'Flat'; $btn.BackColor = C $bg; $btn.ForeColor = [Drawing.Color]::White; $btn.FlatAppearance.BorderColor = C $border; $btn.Cursor = 'Hand'; $btn }

# The option cards' pictures: the agent in the editor's Terminal panel, or in its own window next to the editor.
function Draw-Illo($g, $w, $outside) {
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
  $g.ScaleTransform($w / 220, $w / 220)
  $mono = New-Object Drawing.Font 'Consolas', 8, ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel)
  $small = New-Object Drawing.Font 'Segoe UI', 7, ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel)
  function Rect($c, $x, $y, $rw, $rh, $pen) {
    $g.FillRectangle((B $c), [float]$x, [float]$y, [float]$rw, [float]$rh)
    if ($pen) { $g.DrawRectangle($pen, [float]$x, [float]$y, [float]$rw, [float]$rh) }
  }
  function Cube($cx, $t, $s) {
    $g.FillPolygon((B '#383838'), [Drawing.PointF[]](Pts $cx, $t, ($cx + $s), ($t + $s / 2), ($cx + $s), ($t + 1.5 * $s), $cx, ($t + 2 * $s), ($cx - $s), ($t + 1.5 * $s), ($cx - $s), ($t + $s / 2)))
    $g.DrawPolygon((P '#808080'), [Drawing.PointF[]](Pts $cx, $t, ($cx + $s), ($t + $s / 2), ($cx + $s), ($t + 1.5 * $s), $cx, ($t + 2 * $s), ($cx - $s), ($t + 1.5 * $s), ($cx - $s), ($t + $s / 2)))
    $g.DrawLines((P '#808080'), [Drawing.PointF[]](Pts ($cx - $s), ($t + $s / 2), $cx, ($t + $s), ($cx + $s), ($t + $s / 2)))
    $g.DrawLine((P '#808080'), [float]$cx, [float]($t + $s), [float]$cx, [float]($t + 2 * $s))
  }
  function Chevron($x, $y) {
    $g.DrawLines((P $accent 1.5), [Drawing.PointF[]](Pts $x, $y, ($x + 4), ($y + 3), $x, ($y + 6)))
    $g.DrawString($script:cli, $mono, (B '#C0C0C0'), [float]($x + 8), [float]($y - 3))
  }
  $ew = if ($outside) { 130 } else { 218 }; $eh = if ($outside) { 78 } else { 94 }
  Rect '#151515' 1 1 $ew $eh (P '#484848'); Rect '#0F0F0F' 1.5 1.5 ($ew - 1) 9
  $g.FillEllipse((B '#575757'), 6, 4, 4, 4); $g.FillEllipse((B '#575757'), 12, 4, 4, 4)
  if (-not $outside) {
    Rect '#242424' 6 16 36 42; Rect '#484848' 10 21 24 3; Rect '#484848' 10 28 20 3; Rect '#484848' 10 35 26 3
    Rect '#2F2F2F' 46 16 168 42; Cube 122 21 12
    Rect '#0F0F0F' 6 62 208 28 (P $accent 1.5); Chevron 12 70; Rect '#383838' 12 81 90 3
    $g.DrawString('Terminal', $small, (B '#A0A0A0'), [float]180, [float]63)
  } else {
    Rect '#242424' 6 16 26 58; Rect '#2F2F2F' 36 16 90 58; Cube 81 30 10
    $file = if ($name.Length -gt 12) { 'Start-' + $name.Substring(0, 10) + '...cmd' } else { "Start-$name.cmd" }
    $g.FillPolygon((B '#383838'), [Drawing.PointF[]](Pts 8, 82, 16, 82, 19, 85, 19, 95, 8, 95))
    $g.DrawString($file, $small, (B '#A0A0A0'), [float]22, [float]85)
    Rect '#0F0F0F' 100 30 118 64 (P $accent 1.5); Rect '#151515' 101 31 116 10
    $g.DrawString('Unreal agent', $small, (B '#A0A0A0'), [float]104, [float]31)
    Chevron 107 50; Rect '#383838' 107 63 80 3; Rect '#383838' 107 70 60 3
  }
}

$f = New-Object Windows.Forms.Form -Property @{ Text = 'VibeUE setup'; StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'
  MaximizeBox = $false; MinimizeBox = $false; ShowIcon = $false; BackColor = (C '#242424'); ForeColor = (C '#C0C0C0'); Font = (F 9.75) }
# Dark title bar (Windows 10 20H1+); older Windows keeps its light one.
try {
  Add-Type -Namespace VibeUE -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);'
  $f.Add_HandleCreated({ $on = 1; [void][VibeUE.Dwm]::DwmSetWindowAttribute($f.Handle, 20, [ref]$on, 4) })
} catch {}

# Header
$logo = Add $f Panel 28 24 44 44 @{ BackColor = (C '#0F0F0F') }
$logo.Add_Paint({ param($s, $e) $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
  $g.DrawRectangle((P '#383838'), 0, 0, 43, 43)
  $g.DrawPolygon((P '#C0C0C0' 1.6), [Drawing.PointF[]](Pts 22, 8, 34, 15, 34, 29, 22, 36, 10, 29, 10, 15))
  $g.DrawLines((P $accent 1.6), [Drawing.PointF[]](Pts 16.5, 19, 22, 22, 27.5, 19)); $g.DrawLine((P $accent 1.6), 22, 22, 22, 29)
  $g.FillEllipse((B $accent), 20, 12.5, 4, 4) })
[void](Lbl $f 'Connect your project to an AI agent' 84 20 490 30 '#FFFFFF' (F 14 Bold))
$mono = F 9.5 Regular Consolas
$pw = [Windows.Forms.TextRenderer]::MeasureText("$name.uproject", $mono).Width + 8  # + the Label's own padding
[void](Lbl $f "$name.uproject" 86 52 $pw 18 '#A0A0A0' $mono)
[void](Add $f Label (92 + $pw) 51 60 19 @{ Text = "UE $ver"; BackColor = (C '#383838'); ForeColor = (C '#C0C0C0'); Font = (F 8.5); TextAlign = 'MiddleCenter' })
[void](Lbl $f 'WHERE SHOULD THE AGENT RUN?' 28 92 400 20 '#FFFFFF' (F 9.75 Bold))

# Mode cards: the whole card is the click target; the two radios live in different panels, so Set-Mode groups them.
$cardH = if ($showKey) { 266 } else { 232 }
$cards = @{}; $radios = @{}; $pick = { param($s, $e) Set-Mode $s.Tag }
$text = @{
  inside = 'Inside Unreal', "The agent opens in the editor's Terminal panel, already in your project folder."
  outside = 'Outside Unreal', 'A double-click Start file opens the editor plus the agent in its own window. The agent keeps working when the editor closes.'
}
foreach ($m in 'inside', 'outside') {
  $card = Add $f Panel $(if ($m -eq 'inside') { 28 } else { 306 }) 118 266 $cardH @{ Tag = $m; Cursor = 'Hand' }
  $card.Add_Paint({ param($s, $e) $e.Graphics.DrawRectangle((P $(if ($s.Tag -eq $script:mode) { $accent } else { '#383838' }) 2), 1, 1, $s.Width - 2, $s.Height - 2) })
  $ill = Add $card Panel 12 12 242 106 @{ Tag = $m; BackColor = [Drawing.Color]::Transparent }
  $ill.Add_Paint({ param($s, $e) Draw-Illo $e.Graphics $s.Width ($s.Tag -eq 'outside') })
  $radios[$m] = Add $card RadioButton 12 124 242 24 @{ Tag = $m; AutoCheck = $false; Text = $text[$m][0]; Font = (F 11 Bold); ForeColor = [Drawing.Color]::White; BackColor = [Drawing.Color]::Transparent }
  # Repaint the native (blue) radio glyph in the theme; the control keeps its keyboard and screen-reader behavior.
  $radios[$m].Add_Paint({ param($s, $e) $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $g.FillRectangle((New-Object Drawing.SolidBrush $s.Parent.BackColor), 0, 0, 16, $s.Height)
    $cy = $s.Height / 2
    $g.DrawEllipse((P $(if ($s.Checked) { $accent } else { '#C0C0C0' }) 1.5), 1, $cy - 6, 12, 12)
    if ($s.Checked) { $g.FillEllipse((B $accent), 4, $cy - 3, 6, 6) } })
  [void](Lbl $card $text[$m][1] 12 150 242 72)
  if ($m -eq 'inside' -and $ver -eq '5.7') { [void](Lbl $card 'UE 5.7 has no Terminal panel. MCP still connects.' 12 224 242 34 '#FFB800') }
  foreach ($c in @($card) + @($card.Controls)) { if ($c.Tag) { $c.Add_Click($pick) } else { $c.Tag = $m; $c.Add_Click($pick) } }
  $cards[$m] = $card
}

# Fields
$y = 118 + $cardH + 24
[void](Lbl $f 'Agent' 28 $y 300 20 '#FFFFFF' (F 9.75 Bold))
$agents = [ordered]@{ 'Claude Code' = 'ClaudeCode'; 'Cursor' = 'Cursor'; 'VS Code' = 'VSCode'; 'Gemini CLI' = 'Gemini'; 'Codex' = 'Codex'; 'All of them' = 'All' }
$combo = Add $f ComboBox 28 ($y + 22) 402 30 @{ DropDownStyle = 'DropDownList'; FlatStyle = 'Flat'; BackColor = (C '#383838'); ForeColor = (C '#C0C0C0'); Font = (F 11) }
$combo.Items.AddRange([object[]]@($agents.Keys))
$combo.DrawMode = 'OwnerDrawFixed'; $combo.ItemHeight = 22  # purple selection instead of the system blue
$combo.Add_DrawItem({ param($s, $e) if ($e.Index -lt 0) { return }
  $sel = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -and -not ($e.State -band [Windows.Forms.DrawItemState]::ComboBoxEdit)
  $e.Graphics.FillRectangle((B $(if ($sel) { $accent } else { '#383838' })), $e.Bounds)
  [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $s.Font, $e.Bounds, $(if ($sel) { [Drawing.Color]::White } else { C '#C0C0C0' }), 'VerticalCenter, Left') })
$combo.SelectedItem = @($agents.Keys | Where-Object { $agents[$_] -eq $env:VUE_AGENT })[0]
if ($combo.SelectedIndex -lt 0) { $combo.SelectedIndex = 0 }
$hint = Lbl $f '' 28 ($y + 56) 402 20
[void](Lbl $f 'MCP port' 442 $y 130 20 '#FFFFFF' (F 9.75 Bold))
$port = Field (Add $f TextBox 442 ($y + 22) 130 30 @{ Text = $env:VUE_PORT })
$y += 86
[void](Lbl $f 'Engine folder' 28 $y 300 20 '#FFFFFF' (F 9.75 Bold))
$eng = Field (Add $f TextBox 28 ($y + 22) 440 30 @{ Text = $env:VUE_ENGINE; Font = (F 10 Regular Consolas) })
$browse = Btn (Add $f Button 476 ($y + 22) 96 26 @{ Text = 'Browse...' }) '#383838' '#484848'
$browse.Add_Click({
  $d = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Unreal Engine folder (the one that contains Engine\)'; SelectedPath = $eng.Text }
  if ($d.ShowDialog() -eq 'OK') { $eng.Text = $d.SelectedPath } })
[void](Lbl $f $(if ($env:VUE_ENGINE) { 'Change it only if you have more than one Unreal install.' } else { 'Not found automatically: pick the folder that contains Engine\.' }) 28 ($y + 56) 544 20)
$y += 86
$key = $null
if ($showKey) {
  [void](Lbl $f 'VibeUE API key' 28 $y 300 20 '#FFFFFF' (F 9.75 Bold))
  $link = Add $f LinkLabel 432 $y 140 20 @{ Text = 'Get a free key'; TextAlign = 'TopRight'; LinkColor = (C $accentText); LinkBehavior = 'HoverUnderline'; ActiveLinkColor = (C '#DDA8EA'); BackColor = [Drawing.Color]::Transparent }
  $link.Add_LinkClicked({ Start-Process 'https://www.vibeue.com/login' })
  $key = Field (Add $f TextBox 28 ($y + 22) 544 30 @{ Text = $env:VUE_APIKEY; UseSystemPasswordChar = $true })
  [void](Lbl $f 'UE 5.7 needs it to run tools. Saved only on this PC, never committed.' 28 ($y + 56) 544 20)
  $y += 86
}

# Footer
$foot = Add $f Panel 0 ($y + 4) 600 72 @{ BackColor = (C '#1A1A1A') }
$foot.Add_Paint({ param($s, $e) $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
  $g.DrawLine((P '#383838'), 0, 0, $s.Width, 0)
  $g.DrawEllipse((P $accentText 1.5), 28, 19, 14, 14); $g.DrawLine((P $accentText 1.5), 35, 25, 35, 30); $g.FillEllipse((B $accentText), 34, 21.5, 2, 2) })
$sum = Lbl $foot '' 50 16 312 44 '#C0C0C0'
$cancel = Btn (Add $foot Button 372 16 94 40 @{ Text = 'Cancel'; DialogResult = 'Cancel' }) '#383838' '#484848'
$ok = Btn (Add $foot Button 476 16 96 40 @{ Text = 'Set up'; DialogResult = 'OK'; Font = (F 9.75 Bold) }) $accent $accent
$f.AcceptButton = $ok; $f.CancelButton = $cancel
$f.ClientSize = New-Object Drawing.Size 600, ($y + 76)

function Update-Text {
  $cli = @{ ClaudeCode = 'claude'; All = 'claude'; Gemini = 'gemini'; Codex = 'codex' }[$agents[$combo.SelectedItem]]
  $script:cli = if ($cli) { $cli } else { 'PS>' }
  $where = if ($script:mode -eq 'inside') { 'the Terminal panel' } else { 'the agent window' }
  $hint.Text = if ($cli) { "Runs '$cli' in $where." } else { "Reads the MCP config by itself; $where opens a plain shell." }
  $sum.Text = if ($script:mode -eq 'inside') {
    $(if ($ver -eq '5.7') { 'Sets up the MCP connection' } else { 'Turns on the Terminal plugin' }) + $(if ($build) { ', builds the project and opens the editor.' } else { '.' })
  } else { "Creates a Start-$name shortcut (purple Unreal icon) next to the .uproject" + $(if ($build) { ', builds the project and runs it.' } else { '.' }) }
  foreach ($c in $cards.Values) { $c.Invalidate($true) }
}
function Set-Mode($m) {
  $script:mode = $m
  foreach ($k in 'inside', 'outside') {
    $radios[$k].Checked = $k -eq $m
    $cards[$k].BackColor = C $(if ($k -eq $m) { '#332737' } else { '#2F2F2F' })  # selected: 12% purple over the panel
  }
  Update-Text
}
$combo.Add_SelectedIndexChanged({ Update-Text })
Set-Mode $script:mode
$f.ActiveControl = $ok

if ($f.ShowDialog() -ne 'OK') { exit 1 }
"AGENT=$($agents[$combo.SelectedItem])"; "MODE=$script:mode"; "PORT=$($port.Text)"; "ENGINE=$($eng.Text)"; "APIKEY=$(if ($key) { $key.Text })"
PS
  out="$(VUE_AGENT="${agent:-ClaudeCode}" VUE_MODE="$mode" VUE_PORT="${port:-$defport}" VUE_ENGINE="$( [ -n "$engine" ] && wpath "$engine")" \
    VUE_APIKEY="$apikey" VUE_SHOWKEY=$showkey VUE_NAME="$name" VUE_VER="$guess" VUE_BUILD=$build powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$(wpath "$ps1")")" \
    || { rm -f "$ps1"; die "cancelled"; }
  rm -f "$ps1"
  while IFS='=' read -r k v; do
    v="${v%$'\r'}"
    case "$k" in AGENT) agent="$v" ;; MODE) mode="$v" ;; PORT) port="$v" ;; ENGINE) engine="$(upath "$v")" ;; APIKEY) apikey="$v" ;; esac
  done <<< "$out"
else
  ask() { # ask VAR label default -- keeps a value passed as a flag, takes the default when stdin isn't a terminal
    local v=
    [ -n "${!1}" ] && return
    [ -t 0 ] && read -rp "$2 [$3]: " v
    printf -v "$1" '%s' "${v:-$3}"
  }
  ask agent "Agent (ClaudeCode|Cursor|VSCode|Gemini|Codex|All)" ClaudeCode
  ask mode "Agent runs inside Unreal (editor Terminal) or outside (Start-$name.cmd) (inside|outside)" inside
  ask port "Port" "$defport"
  ask engine "Engine path" "$engine"; engine="$(upath "$engine")"
  [ $showkey = 1 ] && ask apikey "VibeUE API key (required on 5.7 for tool execution)" ""
fi

case "$agent" in ClaudeCode|Cursor|VSCode|Gemini|Codex|All) ;; *) die "unknown agent '$agent'" ;; esac
case "$mode" in inside) external=0 ;; outside) external=1 ;; *) die "agent must run 'inside' or 'outside' Unreal, got '$mode'" ;; esac
[[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "bad port '$port'"
[ -n "$engine" ] || die "could not find Unreal Engine $assoc (checked the registry and the Epic launcher); pass --engine DIR or set UE_ENGINE_PATH"
[ -f "$engine/Engine/Build/Build.version" ] || die "'$engine' is not an Unreal Engine install (no Engine/Build/Build.version)"
ver="$(engine_version "$engine")"
case "$ver" in 5.8) branch=5-8 ;; 5.7) branch=5-7 ;; *) die "engine $ver is not supported (need 5.7 or 5.8)" ;; esac
[ "$ver" = "$assoc" ] || echo "WARNING: $name.uproject is associated with '$assoc' but the engine is $ver"
[ "$ver" = 5.7 ] && [ -z "$apikey" ] && echo "WARNING: no VibeUE API key — 5.7 tool execution needs one (Project Settings > Plugins > VibeUE)"
case "$agent" in ClaudeCode|All) cli=claude ;; Gemini) cli=gemini ;; Codex) cli=codex ;; *) cli= ;; esac

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
  VUE_PORT="$port" VUE_APIKEY="$apikey" VUE_PLUGIN="$plugin" VUE_CLI="$cli" VUE_EXTERNAL=$external "$py" - <<'PY'
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
external = E['VUE_EXTERNAL'] == '1'
def enable_plugins(d):
    plugins = d.setdefault('Plugins', [])
    for name, on in (('ModelContextProtocol', True), ('AllToolsets', True), ('EditorToolset', True), ('Terminal', not external)):
        entry = next((p for p in plugins if p.get('Name') == name), None)
        if entry:
            entry['Enabled'] = on
        elif on:
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
cli = E['VUE_CLI']
if cli and not shutil.which(cli):
    print(f"NOTE: '{cli}' is not on PATH yet; the agent shell runs it on open, so install it first.", file=sys.stderr)
if ver == '5.8' and os.name == 'nt' and not external:
    commands = ['set TERM=xterm-256color', 'cd /d "%s"' % proj.replace('\\', '/')] + ([cli] if cli else [])
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

# 10. --external: a double-click launcher that opens the editor plus the agent in its own PowerShell window.
# That window outlives the editor, so the agent keeps working while the engine is closed (rebuilds, plugin edits);
# it waits for the MCP port first so the agent doesn't start with the server marked failed.
launcher=
if [ $external = 1 ] && [ $win = 1 ]; then
  launcher="Start-$name.cmd"
  waitmcp="Write-Host 'Waiting for the Unreal MCP server on port $port (Ctrl+C to skip)...'; while (\$true) { try { (New-Object Net.Sockets.TcpClient '127.0.0.1', $port).Close(); break } catch { Start-Sleep 2 } }"
  printf '%s\r\n' '@echo off' \
    "rem Generated by setup-vibeue --external: opens the editor and a ${cli:-PowerShell} window for this project." \
    'cd /d "%~dp0"' \
    "start \"\" \"$(wpath "$engine/Engine/Binaries/Win64/UnrealEditor.exe")\" \"%~dp0$name.uproject\"" \
    "start \"Unreal agent - $name\" powershell -NoExit -ExecutionPolicy Bypass -Command \"$waitmcp; $cli\"" > "$launcher"
  # A .cmd can't carry an icon, so a shortcut next to it does: the .uproject icon recolored Unreal purple.
  # Per machine (absolute paths); re-run setup after moving the project.
  ps1="$(mktemp -t vibeue-XXXX).ps1"
  cat > "$ps1" <<'PS'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace VibeUE -Name Ico -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint PrivateExtractIcons(string f, int i, int cx, int cy, IntPtr[] h, int[] id, uint n, uint fl);'
# The icon Explorer shows for .uproject files (Unreal Version Selector), else the editor's own.
$src = $env:VUE_EDITOR; $idx = 0
$reg = (Get-ItemProperty -LiteralPath 'Registry::HKEY_CLASSES_ROOT\Unreal.ProjectFile\DefaultIcon' -ErrorAction SilentlyContinue).'(default)'
if ($reg -match '^"?(.+?)"?(?:,(-?\d+))?$' -and (Test-Path -LiteralPath $Matches[1])) { $src = $Matches[1]; if ($Matches[2]) { $idx = [int]$Matches[2] } }
$h = New-Object IntPtr[] 1
if ([VibeUE.Ico]::PrivateExtractIcons($src, $idx, 256, 256, $h, $null, 1, 0) -lt 1 -or $h[0] -eq [IntPtr]::Zero) { exit 1 }
$icon = [Drawing.Bitmap]::FromHicon($h[0])
# Recolor: the icon is a blue disc (red ~0) under a white U (red 255), so the red channel alone maps
# blue -> Unreal purple and white -> white, antialiased edges in between; alpha kept.
# Matrix rows = source R, G, B, A, offset; columns = output R, G, B, A, (unused).
$p = [Drawing.ColorTranslator]::FromHtml('#A139BF')
$m = New-Object Drawing.Imaging.ColorMatrix (, [float[][]]@(
  [float[]]@((1 - $p.R / 255), (1 - $p.G / 255), (1 - $p.B / 255), 0, 0),
  [float[]]@(0, 0, 0, 0, 0),
  [float[]]@(0, 0, 0, 0, 0),
  [float[]]@(0, 0, 0, 1, 0),
  [float[]]@(($p.R / 255), ($p.G / 255), ($p.B / 255), 0, 1)))
$attr = New-Object Drawing.Imaging.ImageAttributes; $attr.SetColorMatrix($m)
$out = New-Object Drawing.Bitmap 256, 256
$g = [Drawing.Graphics]::FromImage($out)
$g.DrawImage($icon, (New-Object Drawing.Rectangle 0, 0, 256, 256), 0, 0, $icon.Width, $icon.Height, 'Pixel', $attr)
$png = New-Object IO.MemoryStream; $out.Save($png, [Drawing.Imaging.ImageFormat]::Png); $bytes = $png.ToArray()
# .ico = 6-byte header + one 16-byte entry + the PNG (Vista+ reads PNG-compressed 256px icons).
$ico = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ico
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)
$w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)
$w.Write([uint32]$bytes.Length); $w.Write([uint32]22); $w.Write($bytes)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($env:VUE_ICO)) | Out-Null
[IO.File]::WriteAllBytes($env:VUE_ICO, $ico.ToArray())
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($env:VUE_LNK)
$lnk.TargetPath = $env:VUE_CMD; $lnk.WorkingDirectory = [IO.Path]::GetDirectoryName($env:VUE_CMD)
$lnk.IconLocation = "$env:VUE_ICO,0"; $lnk.Description = 'Open the Unreal editor and the agent window'; $lnk.Save()
PS
  if VUE_EDITOR="$(wpath "$engine/Engine/Binaries/Win64/UnrealEditor.exe")" VUE_ICO="$(wpath "$proj/Saved/VibeUE/Start.ico")"     VUE_CMD="$(wpath "$proj/$launcher")" VUE_LNK="$(wpath "$proj/Start-$name.lnk")"     powershell -NoProfile -ExecutionPolicy Bypass -File "$(wpath "$ps1")"; then
    echo "Launcher: $(wpath "$proj/Start-$name.lnk")  (double-click: editor + agent window; purple Unreal icon)"
  else
    echo "Launcher: $(wpath "$proj/$launcher")  (double-click: editor + agent window; icon shortcut failed, see above)"
  fi
  rm -f "$ps1"
fi

# 11-12. Build + launch
if [ $build = 0 ]; then
  echo "Skipped build + launch (--no-build)."
elif [ $win = 0 ]; then
  echo "Build/launch here is Windows-only; use $plugin/BuildAndLaunchGame.sh --engine \"$engine\"."
else
  if [ -d Source ]; then target="${name}Editor" projarg="$(wpath "$uproject")"
  else target=UnrealEditor projarg="-Project=$(wpath "$uproject")"; fi
  # UBT refuses to build while any editor of this engine has Live Coding on (the lock is on the shared UnrealEditor.exe,
  # HotReload.cs). An installed engine only builds into this project, so another open project is safe: skip the check.
  nolc=; [ -f "$engine/Engine/Build/InstalledBuild.txt" ] && nolc=-NoHotReloadFromIDE
  # Via PowerShell: Git Bash cannot run a .bat whose path has spaces (default C:\Program Files\Epic Games\...).
  VUE_BAT="$(wpath "$engine/Engine/Build/BatchFiles/Build.bat")" VUE_TARGET="$target" VUE_PROJARG="$projarg" VUE_NOLC="$nolc" \
    powershell -NoProfile -ExecutionPolicy Bypass -Command '$x = @($env:VUE_NOLC) -ne ""; & $env:VUE_BAT $env:VUE_TARGET Win64 Development $env:VUE_PROJARG -waitmutex @x; exit $LASTEXITCODE' \
    || die "build failed (close this project's editor; with a source-built engine close every editor of it -- Live Coding blocks builds -- then re-run); UBT log: $(wpath "${LOCALAPPDATA:-}")\\UnrealBuildTool\\Log.txt"
  if [ -n "$launcher" ]; then
    cmd //c "$launcher"
  else
    # Start-Process: detached from this console, so closing the window doesn't take the editor with it.
    VUE_EXE="$(wpath "$engine/Engine/Binaries/Win64/UnrealEditor.exe")" VUE_UPROJECT="$(wpath "$uproject")" \
      powershell -NoProfile -Command 'Start-Process -FilePath $env:VUE_EXE -ArgumentList ([char]34 + $env:VUE_UPROJECT + [char]34)'
  fi
  echo "Editor launching; ready when Saved/VibeUE/Signals/editor-<pid>-true.json appears."
fi
