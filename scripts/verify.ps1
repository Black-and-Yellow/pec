[CmdletBinding()]
param(
    [switch]$BackendOnly,
    [switch]$FrontendOnly,
    [switch]$SkipWeb,
    [switch]$SkipAndroid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($BackendOnly -and $FrontendOnly) {
    throw 'BackendOnly and FrontendOnly cannot be used together.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Label
    )

    Write-Host "`n==> $Label"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

function Find-Flutter {
    $command = Get-Command flutter -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $localFlutter = Join-Path $repoRoot '.tools\flutter\bin\flutter.bat'
    if (Test-Path -LiteralPath $localFlutter) {
        return $localFlutter
    }

    throw 'Flutter was not found on PATH or under .tools/flutter.'
}

Push-Location $repoRoot
try {
    $ripgrep = (Get-Command rg -ErrorAction Stop).Source
    $secretPattern = '(?x)(-----BEGIN\ (?:RSA\ |EC\ |OPENSSH\ )?PRIVATE\ KEY-----|AIza[0-9A-Za-z_-]{30,}|AQ\.[0-9A-Za-z_-]{30,}|gh[pousr]_[0-9A-Za-z]{30,}|sk-[A-Za-z0-9_-]{32,}|AKIA[0-9A-Z]{16})'
    $secretMatches = & $ripgrep --hidden --files-with-matches --pcre2 $secretPattern `
        --glob '!**/.git/**' --glob '!**/.tools/**' --glob '!**/tmp/**' `
        --glob '!**/build/**' --glob '!**/.dart_tool/**' --glob '!**/*.pdf' .
    $secretStatus = $LASTEXITCODE
    if ($secretStatus -eq 0) {
        throw "Potential credential material found in: $($secretMatches -join ', ')"
    }
    if ($secretStatus -ne 1) {
        throw "Secret scan failed with exit code $secretStatus."
    }
    Write-Host 'Secret scan passed.'

    if (-not $FrontendOnly) {
        $python = Join-Path $repoRoot 'backend\.venv\Scripts\python.exe'
        if (-not (Test-Path -LiteralPath $python)) {
            throw 'Create the isolated backend environment and install the reviewed dependencies; see README.md under Local development on Windows.'
        }
        Push-Location (Join-Path $repoRoot 'backend')
        try {
            Invoke-Native $python @('-m', 'pip', 'check') 'Backend dependency consistency'
            Invoke-Native $python @('-m', 'pip_audit', '--local', '--progress-spinner', 'off') 'Backend dependency audit'
            Invoke-Native $python @('-m', 'ruff', 'check', '.') 'Backend Ruff'
            Invoke-Native $python @('-m', 'mypy', 'app') 'Backend mypy'
            Invoke-Native $python @(
                '-m', 'pytest', '-p', 'no:cacheprovider', '--cov=app', '--cov-branch',
                '--cov-report=term-missing'
            ) 'Backend pytest with coverage'
        } finally {
            Pop-Location
        }
    }

    if (-not $BackendOnly) {
        $flutter = Find-Flutter
        Push-Location (Join-Path $repoRoot 'frontend')
        try {
            Invoke-Native $flutter @('analyze') 'Flutter analyze'
            Invoke-Native $flutter @('test') 'Flutter tests'

            $gradleWrapper = Join-Path (Get-Location) 'android\gradlew.bat'
            $releaseEnvironmentNames = @(
                'FINGUARD_ALLOW_DEMO_RELEASE',
                'FINGUARD_KEYSTORE_PATH',
                'FINGUARD_KEYSTORE_PASSWORD',
                'FINGUARD_KEY_ALIAS',
                'FINGUARD_KEY_PASSWORD'
            )
            $savedReleaseEnvironment = @{}
            foreach ($name in $releaseEnvironmentNames) {
                $savedReleaseEnvironment[$name] = [Environment]::GetEnvironmentVariable(
                    $name,
                    'Process'
                )
                [Environment]::SetEnvironmentVariable($name, $null, 'Process')
            }
            try {
                Write-Host "`n==> Android aggregate release gate"
                $previousErrorActionPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    $aggregateOutput = & $gradleWrapper `
                        '-p' 'android' 'assemble' '--dry-run' '--offline' 2>&1
                    $aggregateStatus = $LASTEXITCODE
                } finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }
                if ($aggregateStatus -eq 0) {
                    throw 'Aggregate Android assemble bypassed release configuration checks.'
                }
                if (($aggregateOutput -join "`n") -notmatch [regex]::Escape(
                    'Android release builds require --dart-define=API_BASE_URL=https://<host>[/base-path].'
                )) {
                    throw 'Aggregate Android assemble failed for an unexpected reason.'
                }
                Invoke-Native $gradleWrapper @(
                    '-p', 'android', 'assembleDebug', '--dry-run', '--offline'
                ) 'Android debug aggregate control'
            } finally {
                foreach ($name in $releaseEnvironmentNames) {
                    [Environment]::SetEnvironmentVariable(
                        $name,
                        $savedReleaseEnvironment[$name],
                        'Process'
                    )
                }
            }
            if (-not $SkipWeb) {
                Invoke-Native $flutter @('build', 'web', '--release') 'Flutter Web release build'
            }
            if (-not $SkipAndroid) {
                $previousDemoRelease = [Environment]::GetEnvironmentVariable(
                    'FINGUARD_ALLOW_DEMO_RELEASE',
                    'Process'
                )
                try {
                    [Environment]::SetEnvironmentVariable(
                        'FINGUARD_ALLOW_DEMO_RELEASE',
                        'true',
                        'Process'
                    )
                    Invoke-Native $flutter @(
                        'build', 'apk', '--release',
                        '--dart-define=API_BASE_URL=https://example.invalid/'
                    ) 'Flutter Android non-distributable demo release build'
                } finally {
                    [Environment]::SetEnvironmentVariable(
                        'FINGUARD_ALLOW_DEMO_RELEASE',
                        $previousDemoRelease,
                        'Process'
                    )
                }
            }
        } finally {
            Pop-Location
        }
    }

    Write-Host "`nFinGuard verification passed."
} finally {
    Pop-Location
}
