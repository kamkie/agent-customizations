[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path

$global = Get-Content -LiteralPath (Join-Path $repositoryRoot 'global\AGENTS.md') -Raw
$controller = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\orchestrate-work-campaigns\SKILL.md') -Raw
$controllerTemplate = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\orchestrate-work-campaigns\references\controller-template.md') -Raw
$audit = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\orchestrate-work-campaigns\references\handoff-audit-checklist.md') -Raw
$worker = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\execute-campaign-work-item\SKILL.md') -Raw
$workerRecovery = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\execute-campaign-work-item\references\exceptional-recovery.md') -Raw
$forwardCases = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'forward-test-cases.md') -Raw

function Assert-PolicyMatch {
    param(
        [Parameter(Mandatory)][string]$Case,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ($Content -notmatch $Pattern) {
        throw "Campaign policy regression in '$Case': required behavior was not found."
    }
}

Assert-PolicyMatch -Case 'no publication authority stops before hidden fan-out' `
    -Content $controller `
    -Pattern '(?s)publication or review authority is absent.*finish the bounded inventory and stop.*Do not fan out implementation or accumulate hidden local commits'

Assert-PolicyMatch -Case 'short campaign trigger grants visible delivery but not merge or deploy' `
    -Content $global `
    -Pattern '(?s)Start delivery campaign <tracker>.*remote branch pushes.*draft\s+pull or merge requests.*CI monitoring.*opposite-agent review.*does not authorize merge or deployment'
Assert-PolicyMatch -Case 'publication path requires pilot CI review and final head' `
    -Content ($controller + $controllerTemplate) `
    -Pattern '(?s)representative pilot.*draft PR/MR.*CI.*opposite-agent.*final-head'

Assert-PolicyMatch -Case 'direct child steering invalidates stale controller state' `
    -Content ($controller + $audit + $worker + $workerRecovery) `
    -Pattern '(?s)direct user.*contract delta.*stale.*controller.*user'
Assert-PolicyMatch -Case 'audit cannot veto user product decisions' `
    -Content ($controller + $audit) `
    -Pattern '(?s)does not veto or reinterpret.*user.*product or architecture decisions'

Assert-PolicyMatch -Case 'cross-repository exact-ref reads preserve single-repository writes' `
    -Content $worker `
    -Pattern '(?s)Limit writes to the owned repository and paths.*verified exact ref or artifact from another repository.*read'

Assert-PolicyMatch -Case 'applicable denominator includes every outcome' `
    -Content ($controller + $controllerTemplate + $audit) `
    -Pattern '(?s)applicable.*delivered.*blocked.*deferred.*omitted.*omitted\s*=\s*0'

Assert-PolicyMatch -Case 'local commits cannot satisfy delivery' `
    -Content ($controller + $audit + $worker) `
    -Pattern '(?s)local-only commit.*not.*delivered'

$caseCount = ([regex]::Matches($forwardCases, '(?m)^## Case \d+\b')).Count
if ($caseCount -ne 6) {
    throw "Forward-test fixture must contain exactly six input-only cases; found $caseCount."
}
if ($forwardCases -match '(?im)^\s*(Expected|Correct behavior|Answer|Rubric)\s*:') {
    throw 'Forward-test fixture must not reveal expected decisions or a scoring rubric.'
}

Write-Host 'Campaign customization policy tests: OK'
exit 0
