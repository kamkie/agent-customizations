[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

$global = Get-Content -LiteralPath (Join-Path $repositoryRoot 'global\AGENTS.md') -Raw
$controller = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\orchestrate-work-campaigns\SKILL.md') -Raw
$controllerTemplate = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\orchestrate-work-campaigns\references\controller-template.md') -Raw
$audit = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\orchestrate-work-campaigns\references\handoff-audit-checklist.md') -Raw
$worker = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\execute-campaign-work-item\SKILL.md') -Raw
$workerRecovery = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills\execute-campaign-work-item\references\exceptional-recovery.md') -Raw
$forwardCases = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\campaign-forward-test-cases.md') -Raw

function Assert-PolicyMatch {
    param(
        [Parameter(Mandatory)][string]$Case,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Pattern
    )

    $normalizedContent = [regex]::Replace($Content, '\s+', ' ')
    if ($normalizedContent -notmatch $Pattern) {
        throw "Campaign policy regression in '$Case': required behavior was not found. Pattern: $Pattern"
    }
}

function Get-PolicySlice {
    param(
        [Parameter(Mandatory)][string]$Case,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Pattern
    )

    $match = [regex]::Match($Content, $Pattern)
    if (-not $match.Success) {
        throw "Campaign policy regression in '$Case': required section was not found. Pattern: $Pattern"
    }
    return $match.Value
}

$controllerPilot = Get-PolicySlice `
    -Case 'controller pilot step' `
    -Content $controller `
    -Pattern '(?ms)^6\. \*\*Deliver one representative pilot\.\*\*.*?(?=^7\. \*\*)'
$controllerTemplatePilot = Get-PolicySlice `
    -Case 'controller-template pilot step' `
    -Content $controllerTemplate `
    -Pattern '(?ms)^7\. With delivery authority,.*?(?=^8\.)'

Assert-PolicyMatch -Case 'no publication authority stops before hidden fan-out' `
    -Content $controller `
    -Pattern '(?s)publication or review authority is absent.*finish the bounded inventory and stop.*Do not fan out implementation or accumulate hidden local commits'

Assert-PolicyMatch -Case 'short campaign trigger grants visible delivery but not merge or deploy' `
    -Content $global `
    -Pattern '(?s)Start delivery campaign <tracker>.*remote branch pushes.*draft\s+pull or merge requests.*CI monitoring.*opposite-agent review.*does not authorize merge or deployment'
Assert-PolicyMatch -Case 'publication path requires pilot CI review and final head' `
    -Content $controllerPilot `
    -Pattern '(?s)representative pilot.*draft PR/MR.*CI.*opposite-agent.*final-head'
Assert-PolicyMatch -Case 'controller template preserves the pilot delivery gate' `
    -Content $controllerTemplatePilot `
    -Pattern '(?s)representative applicable delivery unit.*draft PR/MR.*CI.*opposite-agent.*final-head'

Assert-PolicyMatch -Case 'controller accepts direct child steering' `
    -Content $controller `
    -Pattern '(?s)direct user\s+instruction.*contract delta.*supersedes stale\s+controller decisions'
Assert-PolicyMatch -Case 'worker notifies on direct steering' `
    -Content $worker `
    -Pattern '(?s)direct user instruction.*contract delta.*supersedes stale controller decisions.*Notify the controller'
Assert-PolicyMatch -Case 'audit invalidates stale controller decisions' `
    -Content $audit `
    -Pattern '(?s)later steering.*contract delta.*controller decisions.*stale'
Assert-PolicyMatch -Case 'recovery preserves direct user corrections' `
    -Content $workerRecovery `
    -Pattern '(?s)Direct user correction after audit or deferral.*Notify the controller.*invalidates'
Assert-PolicyMatch -Case 'controller audit cannot veto user product decisions' `
    -Content $controller `
    -Pattern '(?s)Audit establishes evidence and state.*does not veto or reinterpret user\s+product or architecture decisions'
Assert-PolicyMatch -Case 'audit checklist cannot veto user product decisions' `
    -Content $audit `
    -Pattern '(?s)does not veto or reinterpret.*direct user product or architecture decision'

Assert-PolicyMatch -Case 'cross-repository exact-ref reads preserve single-repository writes' `
    -Content $worker `
    -Pattern '(?s)Limit writes to the owned repository and paths.*verified exact ref or artifact from another repository.*read'

Assert-PolicyMatch -Case 'controller reconciles the applicable denominator' `
    -Content $controller `
    -Pattern '(?s)Reconcile applicable delivery units.*delivered.*blocked.*deferred.*omitted.*omitted\s*=\s*0'
Assert-PolicyMatch -Case 'audit reconciles every applicable delivery unit' `
    -Content $audit `
    -Pattern '(?s)every applicable delivery unit.*delivered, blocked, deferred, or omitted.*omitted\s*=\s*0'

Assert-PolicyMatch -Case 'controller blocks local-only commits at publication' `
    -Content $controller `
    -Pattern '(?s)local-only commits as blocked at\s+publication'
Assert-PolicyMatch -Case 'audit rejects local commits as delivery' `
    -Content $audit `
    -Pattern '(?s)local-only commit.*not a delivered campaign result'
Assert-PolicyMatch -Case 'worker cannot claim local-only delivery' `
    -Content $worker `
    -Pattern '(?s)local-only commit is\s+not delivered or complete delivery'

$caseCount = ([regex]::Matches($forwardCases, '(?m)^## Case \d+\b')).Count
if ($caseCount -ne 6) {
    throw "Forward-test fixture must contain exactly six input-only cases; found $caseCount."
}
if ($forwardCases -match '(?im)^\s*(Expected|Correct behavior|Answer|Rubric)\s*:') {
    throw 'Forward-test fixture must not reveal expected decisions or a scoring rubric.'
}

Write-Host 'Campaign customization policy tests: OK'
exit 0
