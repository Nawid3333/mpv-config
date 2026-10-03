# Settings for PSScriptAnalyzer, used by .github/workflows/powershell-lint.yml and by
# `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1`.
@{
    Severity     = @('Error', 'Warning')

    # Write-Host is how these interactive scripts talk to the person running them
    # (coloured status lines). The rule is meant for reusable modules whose output other
    # code captures, which these are not.
    # PSAvoidUsingPositionalParameters is Information-level, so `Severity` above already
    # keeps it out of CI - but VS Code's PowerShell extension ignores `Severity` and showed
    # all 57 of them in tests/run-tests.ps1 (2026-09-27), nearly all calls to its own small
    # helpers (Test-Check, Add-Result, Initialize-Clip, Invoke-Mpv) where positional
    # arguments are the idiom. Excluded by name, so the editor shows what CI shows.
    ExcludeRules = @('PSAvoidUsingWriteHost', 'PSAvoidUsingPositionalParameters')
}
