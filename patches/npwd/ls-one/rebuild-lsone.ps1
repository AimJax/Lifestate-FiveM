<#
.SYNOPSIS
  Reproducible LS One NPWD phone-shell build & deploy (Windows).

.DESCRIPTION
  Clones the pinned upstream NPWD baseline, applies the LS One source patch,
  builds the phone frontend, re-applies the production bundle patches
  (disabledApps + goBack fallback), and deploys dist/html into the live
  resource. Creates everything it needs; depends on no Temp leftovers.

  Run from the repository root:
    .\patches\npwd\ls-one\rebuild-lsone.ps1 [-WorkDir <path>] [-SkipInstall]

  Never touches: server-side NPWD state, app IDs, database, federation
  configuration (beyond the documented backfix chunk rename), gameplay.
#>
[CmdletBinding()]
param(
  # D:-based default per the permanent project storage rule (C: is critically
  # low on space). Override with -WorkDir for one-off alternate locations.
  [string]$WorkDir = 'D:\Build\NPWD\npwd-src',
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Continue'
# NOTE: native tools (git/pnpm) write progress to stderr; that must NOT
# terminate the script. Every step verifies its own outcome explicitly
# ($LASTEXITCODE, rev-parse, occurrence counts) and calls Fail() on mismatch.

# Process-local temp redirect (C: is critically low on space). Affects this
# process and its children only; never touches Windows user/system settings.
$BuildTemp = 'D:\Temp'
New-Item -ItemType Directory -Force -Path $BuildTemp | Out-Null
$env:TEMP = $BuildTemp
$env:TMP = $BuildTemp

$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$PatchDir = $PSScriptRoot
$SourcePatch = Join-Path $PatchDir 'ls-one-shell.patch'
$NPWD_PIN = 'f536882972b66742e8619559b9f7407fffb91942'
$NPWD_URL = 'https://github.com/project-error/npwd.git'
$LiveHtml = Join-Path $RepoRoot 'resources\[npwd]\npwd\dist\html'

function Fail($msg) { throw "rebuild-lsone: $msg" }
function Step($msg) { Write-Host "==> $msg" }

# 0. Prerequisites -----------------------------------------------------------
foreach ($cmd in @('node', 'pnpm', 'git')) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Fail "$cmd not found on PATH" }
}
if (-not (Test-Path -LiteralPath $SourcePatch)) { Fail "missing $SourcePatch" }

# 1. Pinned baseline ----------------------------------------------------------
Step "preparing upstream baseline $NPWD_PIN in $WorkDir"
if ((Test-Path -LiteralPath (Join-Path $WorkDir '.git')) -and
    ((git -C $WorkDir rev-parse HEAD 2>$null) -eq $NPWD_PIN)) {
  Step 'work dir already holds the pinned commit; reusing'
} else {
  if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  git clone $NPWD_URL $WorkDir 2>&1 | Out-Null
  git -C $WorkDir checkout $NPWD_PIN 2>&1 | Out-Null
  if ((git -C $WorkDir rev-parse HEAD) -ne $NPWD_PIN) { Fail 'baseline checkout mismatch' }
}

# 2. LS One source patch ------------------------------------------------------
Step 'applying LS One source patch'
git -C $WorkDir checkout -- apps/phone/src pnpm-workspace.yaml 2>&1 | Out-Null
git -C $WorkDir apply --check $SourcePatch 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail 'ls-one-shell.patch does not apply cleanly (see patches/npwd/ls-one/README.md)' }
git -C $WorkDir apply $SourcePatch 2>&1 | Out-Null
$patchedFiles = @(Select-String -LiteralPath $SourcePatch -Pattern '^diff --git a/(.+) b/' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
$changedFiles = @(git -C $WorkDir status --short | Where-Object { $_ -match '^ M' } | ForEach-Object { $_.Substring(3).Trim() } | Sort-Object -Unique)
$missing = @($patchedFiles | Where-Object { $changedFiles -notcontains $_ })
if ($missing.Count -gt 0) { Fail ('patch applied but missing changes in: ' + ($missing -join ', ')) }

# 3. Dependencies + build ------------------------------------------------------
Push-Location -LiteralPath $WorkDir
try {
  if (-not $SkipInstall) {
    Step 'pnpm install'
    pnpm approve-builds esbuild core-js core-js-pure '@sentry/cli' '@swc/core' 2>&1 | Out-Null
    pnpm install 2>&1 | Out-Null
  }
  Step 'building @npwd/keyos'
  pnpm --filter '@npwd/keyos' build 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail 'keyos build failed' }
  Step 'building @npwd/nui (phone frontend)'
  pnpm --filter '@npwd/nui' build 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail 'phone frontend build failed' }
} finally {
  Pop-Location
}

$BuildHtml = Join-Path $WorkDir 'dist\html'
if (-not (Test-Path -LiteralPath (Join-Path $BuildHtml 'index.html'))) { Fail 'build output missing dist/html' }

# 4. Production bundle patches -------------------------------------------------
function Assert-Replace($file, $old, $new, $label) {
  $t = Get-Content -LiteralPath $file -Raw
  $n = ([regex]::Matches($t, [regex]::Escape($old))).Count
  if ($n -ne 1) { Fail "${label}: expected 1 occurrence, found $n (see re-apply guides in patches/npwd/)" }
  Set-Content -LiteralPath $file -Value $t.Replace($old, $new) -NoNewline
  Step "$label applied"
}

$indexBundle = Get-ChildItem -LiteralPath (Join-Path $BuildHtml 'assets') -Filter 'index-*.js' |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $indexBundle) { Fail 'index bundle not found in fresh build' }

Step 're-applying disabledApps bundle patch'
Assert-Replace $indexBundle 'i=Hg().iconSet.value,t=g6(()=>Ale.map(s=>{' 'i=Hg().iconSet.value,npwdDis=Ve(xi.resourceConfig)?.disabledApps||[],t=g6(()=>Ale.map(s=>{' 'disabledApps/fragment-1'
Assert-Replace $indexBundle 'isDisabled:s.disable}:{' 'isDisabled:s.disable||npwdDis.includes(s.id)}:{' 'disabledApps/fragment-2'
Assert-Replace $indexBundle 'isDisabled:s.disable}}),[e,i,a])' 'isDisabled:s.disable||npwdDis.includes(s.id)}}),[e,i,a,npwdDis])' 'disabledApps/fragment-3'

Step 're-applying goBack fallback bundle patch'
$routerChunk = Get-ChildItem -LiteralPath (Join-Path $BuildHtml 'assets') -Filter '__federation_shared_react-router-dom-*.js' |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $routerChunk) { Fail 'router federation chunk not found in fresh build' }
Assert-Replace $routerChunk 'function R(d){t.go(d)}function k(){R(-1)}' 'function R(d){t.go(d)}function k(){var npwdP=F.location.pathname;if(npwdP==="/")return;var npwdSeg=npwdP.split("/").filter(Boolean).length;if(npwdSeg<=1){w("/");return}var npwdBefore=F.location.pathname;R(-1);setTimeout(function(){var npwdNow=F.location.pathname;npwdNow===npwdBefore&&w("/")},120)}' 'goBack/fragment-1'
$backfixName = '__federation_shared_react-router-dom-lifestate-backfix.js'
Rename-Item -LiteralPath $routerChunk -NewName $backfixName
$oldRouterName = Split-Path -Leaf $routerChunk
foreach ($f in @($indexBundle, (Join-Path $BuildHtml 'assets\__federation_fn_import.js'))) {
  $t = Get-Content -LiteralPath $f -Raw
  $n = ([regex]::Matches($t, [regex]::Escape($oldRouterName))).Count
  if ($n -lt 1) { Fail "router chunk reference missing in $f" }
  Set-Content -LiteralPath $f -Value $t.Replace($oldRouterName, $backfixName) -NoNewline
}
Step 'goBack chunk renamed + references updated'

# 5. Deploy --------------------------------------------------------------------
Step "deploying to $LiveHtml"
foreach ($name in @('assets', 'media', 'index.html', 'iframe.webcomp.js')) {
  $dst = Join-Path $LiveHtml $name
  if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
}
Copy-Item -LiteralPath (Join-Path $BuildHtml 'assets') -Destination (Join-Path $LiveHtml 'assets') -Recurse
Copy-Item -LiteralPath (Join-Path $BuildHtml 'media') -Destination (Join-Path $LiveHtml 'media') -Recurse
Copy-Item -LiteralPath (Join-Path $BuildHtml 'index.html') -Destination (Join-Path $LiveHtml 'index.html')
Copy-Item -LiteralPath (Join-Path $BuildHtml 'iframe.webcomp.js') -Destination (Join-Path $LiveHtml 'iframe.webcomp.js')

# 6. Verify ---------------------------------------------------------------------
$css = Get-ChildItem -LiteralPath (Join-Path $LiveHtml 'assets') -Filter 'index-*.css' |
  Select-Object -First 1 -ExpandProperty FullName
$cssText = Get-Content -LiteralPath $css -Raw
$jsText = Get-Content -LiteralPath $indexBundle -Raw
$mainJs = Get-ChildItem -LiteralPath (Join-Path $LiveHtml 'assets') -Filter 'index-*.js' |
  Select-Object -First 1 -ExpandProperty FullName
$mainText = Get-Content -LiteralPath $mainJs -Raw
$failedChecks = New-Object System.Collections.Generic.List[string]
if (-not $cssText.Contains('PhoneFrame:before')) { $failedChecks.Add('LS One frame CSS') }
if (-not $mainText.Contains('bg-white/85')) { $failedChecks.Add('LS One gesture pill') }
if (-not ($jsText.Contains('npwdDis=') -and $jsText.Contains('disabledApps||'))) { $failedChecks.Add('disabledApps patch') }
if (-not (Test-Path -LiteralPath (Join-Path $LiveHtml "assets\$backfixName"))) { $failedChecks.Add('goBack backfix chunk') }
$staleRef = Get-ChildItem -LiteralPath $LiveHtml -Recurse -File |
  Select-String -Pattern 'react-router-dom-770100b8' | Select-Object -First 1
if ($staleRef) { $failedChecks.Add(('stale router ref: ' + $staleRef.Path)) }
if ($failedChecks.Count -gt 0) { Fail ('verification failed: ' + ($failedChecks -join '; ')) }

Step 'LS One rebuild + deploy verified. Restart npwd and check live.'
