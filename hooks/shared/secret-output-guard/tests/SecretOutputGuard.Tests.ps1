[CmdletBinding()]
param()

# Deterministic allow and deny cases for the secret-output guard. Every command
# here is only parsed, never run, and every name and value is a dummy.

$ErrorActionPreference = 'Stop'
$hookScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'SecretOutputGuard.PreToolUseHook.ps1'
$pwsh = (Get-Process -Id $PID).Path
$assertionCount = 0
$failures = [Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertionCount++
}

function Split-Cases {
    param([string]$Block)
    return @($Block -split "`r?`n" | Where-Object { $_.Trim() })
}

function Test-Cases {
    param([string]$Tool, [AllowNull()][string]$Expected, [string[]]$Commands)
    foreach ($command in $Commands) {
        $actual = Get-SecretOutputFinding -Command $command -ToolName $Tool
        if ([string]$actual -cne [string]$Expected) {
            $want = if ($Expected) { "deny ($Expected)" } else { 'allow' }
            $got = if ($actual) { "deny ($actual)" } else { 'allow' }
            $script:failures.Add("[$Tool] expected $want, got ${got}: $command")
        }
        $script:assertionCount++
    }
}

. $hookScript

# --- Denied: Kubernetes Secret values -----------------------------------------
Test-Cases -Tool 'Bash' -Expected 'kubectl' -Commands (Split-Cases @'
kubectl get secret app -o yaml
kubectl get secrets -n prod -o json
kubectl -n prod get secret app -ojson
kubectl --context dev get secret app --output=yaml
kubectl get secret/app -o yaml
kubectl get secrets,configmaps -o yaml
kubectl get configmap/app secret/app -o yaml
kubectl get pod/web Secret/app -o json
kubectl get secret app -o name --output yaml
kubectl get secret app --output name -o yaml
kubectl get secret app -o jsonpath='{.data.password}'
kubectl get secret app -o jsonpath="{.data.password}"
kubectl get secret app -o jsonpath={.data.password}
kubectl get secret app -o=jsonpath='{.data}'
kubectl get secret app -o jsonpath='{@}'
kubectl get secret app -o jsonpath='{.stringData}'
kubectl get secrets -o jsonpath='{.items[*]}'
kubectl get secret app -o jsonpath='{.metadata.annotations}'
kubectl get secret app -o jsonpath='{.metadata.name}{.data.password}'
kubectl get secret app -o jsonpath='{..password}'
kubectl get secret app -o jsonpath='{.metadata.name .data}'
kubectl get secret app -o jsonpath='{.metadata.namex}{.metadata.labels,.data}'
kubectl get secret app -o custom-columns='NAME:.metadata.name .data'
kubectl get secret app -o jsonpath='{.data.password}' | base64 -d -o value.txt | sha256sum
kubectl get secret app -o go-template='{{.data.password | base64decode}}'
kubectl get secret app -o go-template='{{range $k, $v := .data}}{{$k}}{{end}}'
kubectl get secret app --template='{{.data}}'
kubectl get secret app -o custom-columns=NAME:.metadata.name,K:.data
kubectl get secret app -o jsonpath-file=query.txt
kubectl get secret app -o jsonpath='{.data.password}' | base64 -d
kubectl get secret app -o yaml | grep -v password
kubectl get secret app -o yaml | sed 's/password:.*/password: REDACTED/'
kubectl get secret app -o yaml > secret.yaml
kubectl get secret app -o json | jq '.data'
kubectl get secret app -o json | tee out.json | sha256sum
kubectl get secret app -o json | sha256sum --check
kubectl get secret app -o yaml | md5 -p
kubectl get secret app -o yaml | shasum -a 256 -c
kubectl get secret app -o yaml | sha256sum notes.txt
kubectl get secret app -o yaml | openssl dgst -sha256 -out digest.txt -hmac key
kubectl get secret app -o yaml || sha256sum
kubectl get secret app -o yaml >&2 | sha256sum
KUBECONFIG=/tmp/kube kubectl get secret app -o yaml
env KUBECONFIG=/tmp/kube kubectl get secret app -o yaml
sudo -u deploy kubectl get secret app -o yaml
timeout 30 kubectl get secret app -o yaml
/usr/local/bin/kubectl get secret app -o yaml
kubectl.exe get secret app -o yaml
"kubectl" get secret app -o yaml
kubectl get sec""ret app -o yaml
kubectl get sec\ret app -o yaml
2>/dev/null kubectl get secret app -o yaml
2> /dev/null kubectl get secret app -o yaml
kubectl get 2>/dev/null secret app -o yaml
< /dev/null kubectl get secret app -o yaml
kubectl get secret app -o json | 2>/dev/null jq .
cd repo && kubectl get secret app -o yaml
echo start; kubectl get secret app -o yaml
kubectl get pods; kubectl get secret app -o yaml
bash -c "kubectl get secret app -o yaml"
bash -lc 'kubectl get secret app -o yaml'
bash -cx 'kubectl get secret app -o yaml'
bash -o pipefail -xc "kubectl get secret app -o yaml"
sh -c -e 'kubectl get secret app -o yaml'
sudo --user root kubectl get secret app -o yaml
sudo --user=root kubectl get secret app -o yaml
env --unset HTTPS_PROXY kubectl get secret app -o yaml
timeout --signal KILL 30 kubectl get secret app -o yaml
time -p kubectl get secret app -o yaml
watch -n 5 "kubectl get secret app -o yaml"
su - deploy -c 'kubectl get secret app -o yaml'
wsl kubectl get secret app -o yaml
wsl -d Ubuntu -- kubectl get secret app -o yaml
bash <<< "kubectl get secret app -o yaml"
sh <<<'kubectl get secret app -o yaml'
pwsh -Command "kubectl get secret app -o yaml"
eval "kubectl get secret app -o yaml"
PASS=$(kubectl get secret app -o jsonpath='{.data.password}' | base64 -d)
echo "$(kubectl get secret app -o jsonpath='{.data.password}')"
echo `kubectl get secret app -o yaml`
git commit -m "Run `kubectl get secret app -o yaml` here"
if kubectl get secret app -o yaml; then echo ok; fi
for s in a b; do kubectl get secret $s -o yaml; done
kubectl get secret ${NAME} -o yaml
kubectl get secret ${NAME:-app} -o yaml
printf '%s\n' ${unused:-$(kubectl get secret app -o yaml)}
echo "${unused:-$(kubectl get secret app -o yaml)}"
echo ${unused:-`kubectl get secret app -o yaml`}
echo ${#NAME}; kubectl get secret app -o yaml
echo ${NAME/ #x/y}; kubectl get secret app -o yaml
kubectl get secret $(cat name.txt) -o yaml
xargs -I {} kubectl get secret {} -o yaml
(kubectl get secret app -o yaml)
{ kubectl get secret app -o yaml; }
kubectl get secret app -o yaml &
diff <(kubectl get secret a -o yaml) <(kubectl get secret b -o yaml)
'@)
Test-Cases -Tool 'Bash' -Expected 'kubectl' -Commands @(
    "echo start`nkubectl get secret app -o yaml",
    "kubectl get secret app \`n  -o yaml",
    "kubectl get secret app -o yaml |`n  cat",
    "bash <<'EOF'`nkubectl get secret app -o yaml`nEOF",
    "cat <<EOF`nnote`nEOF`nkubectl get secret app -o yaml",
    # PowerShell text reaching a shell tool that is not named PowerShell.
    "kubectl get secret app ```n  -o yaml"
)
Test-Cases -Tool 'PowerShell' -Expected 'kubectl' -Commands (Split-Cases @'
kubectl get secret app -o yaml
kubectl get secret app -o jsonpath="{.data.password}"
$s = kubectl get secret app -o json | ConvertFrom-Json
kubectl get secret app -o yaml | Select-String -NotMatch password
kubectl get secret app -o json | Out-File secret.json
& kubectl get secret app -o yaml
& "C:\tools\kubectl.exe" get secret app -o yaml
foreach ($n in $names) { kubectl get secret $n -o yaml }
foreach($n in $names){kubectl get secret $n -o yaml}
$names | ForEach-Object { kubectl get secret $_ -o json }
$names | %{ kubectl get secret $_ -o json }
(kubectl get secret app -o json | ConvertFrom-Json).data
Invoke-Expression "kubectl get secret app -o yaml"
Write-Output "value: $(kubectl get secret app -o jsonpath='{.data.password}')"
if ($true) { kubectl get secret app -o yaml }
$env:KUBECONFIG = 'kube.yaml'; kubectl get secret app -o yaml
cmd /c "kubectl get secret app -o yaml"
foreach ($s in kubectl get secrets -o json | ConvertFrom-Json) { $s }
wsl bash -c "kubectl get secret app -o yaml"
'@)
Test-Cases -Tool 'PowerShell' -Expected 'kubectl' -Commands @(
    "kubectl get secret app ```n  -o yaml",
    "`$body = @`"`nvalue `$(kubectl get secret app -o jsonpath='{.data.password}')`n`"@"
)

# --- Denied: Azure Key Vault secret values ------------------------------------
Test-Cases -Tool 'Bash' -Expected 'az' -Commands (Split-Cases @'
az keyvault secret show --vault-name kv --name db-password
az keyvault secret show --vault-name kv --name db-password --query value -o tsv
az keyvault secret show --vault-name kv -n db-password --query "{name:name, value:value}"
az keyvault secret show --id https://kv.vault.azure.net/secrets/db-password -o json
az keyvault secret show --vault-name kv -n db-password --query '@'
az keyvault secret show --vault-name kv -n db-password --query=value
az keyvault secret show --vault-name kv -n db-password --query value -o tsv | clip
az keyvault secret show --vault-name kv -n db-password --query value -o tsv > value.txt
VALUE=$(az keyvault secret show --vault-name kv -n db-password --query value -o tsv)
az.cmd keyvault secret show --vault-name kv -n db-password
az keyvault sec""ret show --vault-name kv -n db-password
az keyvault secret show --vault-name kv -n db-password -o none --output json
2>/dev/null az keyvault secret show --vault-name kv -n db-password
'@)
Test-Cases -Tool 'PowerShell' -Expected 'az' -Commands (Split-Cases @'
$v = az keyvault secret show --vault-name kv -n db-password --query value -o tsv
az keyvault secret show --vault-name kv -n db-password | ConvertFrom-Json
(az keyvault secret show --vault-name kv -n db-password --query value -o tsv).Length
'@)

# --- Denied: GitLab CI/CD variable values -------------------------------------
Test-Cases -Tool 'Bash' -Expected 'glab' -Commands (Split-Cases @'
glab api projects/123/variables
glab api projects/123/variables | head -20
glab api "groups/42/variables?per_page=100" --paginate
glab api projects/123/variables/DEPLOY_TOKEN
glab api -X GET projects/123/variables
glab api --method=get projects/123/variables -f per_page=100
glab api projects/123/variables | jq '.[] | select(.key == "A")'
glab api projects/123/variables | jq -r '.[] | "\(.key)=\(.value)"'
glab api projects/123/variables | jq .
glab api projects/123/variables | jq -r --arg k A '.[].key'
glab variable get DEPLOY_TOKEN
glab var get DEPLOY_TOKEN -g group
glab variable list -F json
glab variable list --output json | jq .
glab variable list --jq '.[] | .value'
glab variable export
glab variable export --output env > vars.env
glab.exe variable get DEPLOY_TOKEN
gl''ab var get DEPLOY_TOKEN
glab variable list -F text --output json
glab api --method POST -X GET projects/123/variables
glab --repo group/project variable get DEPLOY_TOKEN
glab -R group/project variable export
glab --repo=group/project variable list --output json
glab --hostname gitlab.example.com api projects/123/variables
glab api projects/123/variables --silent=false
2>/dev/null glab variable get DEPLOY_TOKEN
glab api projects/123/variables --silent --silent=false
'@)
Test-Cases -Tool 'PowerShell' -Expected 'glab' -Commands (Split-Cases @'
glab api projects/123/variables | ConvertFrom-Json
glab api projects/123/variables | ConvertFrom-Json | Select-Object key, value
glab api projects/123/variables | ConvertFrom-Json | ForEach-Object { $_.value }
$vars = glab api projects/123/variables | ConvertFrom-Json
'@)

# --- Allowed -------------------------------------------------------------------
Test-Cases -Tool 'Bash' -Expected $null -Commands (Split-Cases @'
kubectl get secret app
kubectl get secrets -A
kubectl get secret app -o wide
kubectl get secret app -o name
kubectl get secret app -o yaml --output name
az keyvault secret show --vault-name kv -n db-password --output json -o none
glab variable list --output json -F text
kubectl describe secret app
kubectl get secret app -o jsonpath='{.metadata.name}'
kubectl get secret app -o jsonpath={.metadata.name}
kubectl get secrets -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
kubectl get secrets -o jsonpath='{.items[*].metadata.name}'
kubectl get secret app -o jsonpath='{.type}'
kubectl get secret app -o jsonpath='{.metadata.labels.app}'
kubectl get secret app -o jsonpath='{.metadata.namespace}/{.metadata.name}'
kubectl get secret app -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}'
kubectl get secret app -o jsonpath='{.metadata.ownerReferences[0].name}'
kubectl get secret app -o jsonpath='{.metadata.annotations.owner}'
kubectl get secrets -o custom-columns=NAME:.metadata.name,TYPE:.type
kubectl get secret app -o go-template='{{.metadata.name}}'
kubectl get secrets -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}'
kubectl get configmap app -o yaml
kubectl get pods -o json
kubectl get pod secret -o yaml
kubectl get configmap app secret -o yaml
kubectl get configmap/app pod/secret -o yaml
kubectl delete secret app
kubectl create secret generic app --from-literal=key=dummy --dry-run=client -o yaml
kubectl get secret app -o json | sha256sum
kubectl get secret app -o json | sha256sum -
kubectl get secret app -o json | shasum -a 256
kubectl get secret app -o json | md5 -q
kubectl get secret app -o json | openssl sha256 -r
kubectl get secret app -o jsonpath='{.data.password}' | base64 -d | sha256sum
kubectl get secret app -o yaml 2>/dev/null | sha256sum | cut -c1-12
kubectl get secret app -o yaml 2> /dev/null | sha256sum
2>/dev/null kubectl get secret app -o yaml | 2>/dev/null sha256sum
2>/dev/null kubectl get secret app
kubectl get secret ${NAME:-app}
bash -cx 'kubectl get secret app'
time kubectl get secret app
watch -n 5 "kubectl get secret app"
cat <<< "kubectl get secret app -o yaml"
sudo --user root kubectl get secret app
sudo --user root grep -rn "kubectl get secret app -o yaml" docs/
echo ${NOTE:-kubectl get secret app -o yaml}
kubectl get secret app -o jsonpath='{.data.password}' | base64 --decode | tr -d '\n' | openssl dgst -sha256
a=$(kubectl get secret app -o jsonpath='{.data.password}' | base64 -d | sha256sum); echo "$a"
git commit -m "Deny kubectl get secret -o yaml in the guard"
git commit -m 'Deny `kubectl get secret app -o yaml` in the guard'
grep -rn "kubectl get secret app -o yaml" docs/
rg 'az keyvault secret show' .
echo kubectl get secret app -o yaml
echo "run; kubectl get secret app -o yaml"
# kubectl get secret app -o yaml
echo done # kubectl get secret app -o yaml
ls secrets/ && cat docs/variables.md
git status
az keyvault secret show --vault-name kv -n db-password --query attributes
az keyvault secret show --vault-name kv -n db-password --query id -o tsv
az keyvault secret show --vault-name kv -n db-password --query "{name:name, enabled:attributes.enabled}"
az keyvault secret show --vault-name kv -n db-password --query "[id, contentType]"
az keyvault secret show --vault-name kv -n db-password -o none
az keyvault secret show --vault-name kv -n db-password --query value -o tsv | sha256sum
az keyvault secret list --vault-name kv
az keyvault show --name kv
glab variable list
glab variable list -g group --per-page 100
glab --repo group/project variable list
glab -R group/variable mr list
glab variable list -F json --jq '.[].key'
glab variable export --jq '[.[] | .key] | sort'
glab api projects/123/variables | jq -r '.[].key'
glab api projects/123/variables | jq '[.[] | .key] | sort'
glab api projects/123/variables | jq 'map(.key)' | head -20
glab api projects/123/variables | jq length
glab api projects/123/variables/DEPLOY_TOKEN | jq -r .key
glab api projects/123/variables --silent
glab api projects/123/variables --silent=true
glab api -X PUT projects/123/variables/FLAG -f value=dummy
glab api projects/123/pipelines
glab api "projects/123/merge_requests?search=variables"
glab variable get DEPLOY_TOKEN | sha256sum
glab variable set FLAG -v dummy
glab mr list
'@)
Test-Cases -Tool 'Bash' -Expected $null -Commands @(
    "git commit -m `"`$(cat <<'EOF'`nGuard secret output`n`nkubectl get secret app -o yaml is denied.`nEOF`n)`"",
    "gh pr create --title guard --body `"`$(cat <<'EOF'`naz keyvault secret show --name x`nglab api projects/1/variables`nEOF`n)`"",
    "cat > notes.md <<EOF`nkubectl get secret app -o yaml`nEOF",
    "cat <<EOF | grep kubectl`nkubectl get secret app -o yaml`nEOF",
    "# note`n# kubectl get secret app -o yaml`ngit status"
)
Test-Cases -Tool 'PowerShell' -Expected $null -Commands (Split-Cases @'
kubectl get secret app
kubectl describe secret app
kubectl get secret app -o jsonpath='{.metadata.name}'
kubectl get secret app -o json | sha256sum
Write-Output 'az keyvault secret show --name x'
Write-Output "kubectl get secret app -o yaml"
"kubectl get secret app -o yaml" | Set-Content notes.txt
$cmd = "kubectl get secret app -o yaml"
foreach ($s in kubectl get secrets -o name) { $s }
Select-String -Pattern "glab api projects/1/variables" -Path docs/guide.md
git commit -m "Deny `kubectl get secret app -o yaml` in the guard"
Get-ChildItem secrets; Get-Content docs/variables.md
az keyvault secret show --vault-name kv -n db-password --query attributes
az keyvault secret show --vault-name kv -n db-password --query "{name:name, id:id}"
glab variable list
glab api projects/123/variables | ConvertFrom-Json | Select-Object -ExpandProperty key
glab api projects/123/variables | ConvertFrom-Json | Select-Object key, protected
glab api projects/123/variables | ConvertFrom-Json | ForEach-Object key
glab api projects/123/variables | jq -r '.[].key'
'@)
Test-Cases -Tool 'PowerShell' -Expected $null -Commands @(
    "`$body = @'`nkubectl get secret app -o yaml`n'@`nSet-Content notes.md `$body",
    "`$body = @`"`naz keyvault secret show --name x`n`"@`nSet-Content notes.md `$body",
    "# kubectl get secret app -o yaml`ngit status",
    "<#`nkubectl get secret app -o yaml`n#>`nGet-Date",
    "Get-Date <# kubectl get secret app -o yaml #>"
)
# A block comment hides only its own text, also in a tool whose shell is unknown.
Test-Cases -Tool 'Bash' -Expected $null -Commands @("<#`nkubectl get secret app -o yaml`n#>`nGet-Date")
Test-Cases -Tool 'PowerShell' -Expected 'kubectl' -Commands @(
    "<# note #> kubectl get secret app -o yaml",
    "<#`nnote`n#>`nkubectl get secret app -o yaml"
)

if ($failures.Count -gt 0) {
    throw ("Secret-output guard decisions differ from expectations:`n" + ($failures -join "`n"))
}

# --- Hook protocol -------------------------------------------------------------
function Invoke-Guard {
    param([string]$PayloadText)
    return ($PayloadText | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookScript -ManagedHookId 'secret-output-guard-pre-tool-use' | Out-String)
}

function New-Payload {
    param([string]$Tool, $ToolInput)
    return [ordered]@{ hook_event_name = 'PreToolUse'; tool_name = $Tool; tool_input = $ToolInput } | ConvertTo-Json -Compress -Depth 5
}

$kubectlDecision = (Invoke-Guard (New-Payload 'Bash' ([ordered]@{ command = 'kubectl get secret app -o yaml' }))) | ConvertFrom-Json
Assert-True ($kubectlDecision.hookSpecificOutput.hookEventName -eq 'PreToolUse') 'A denial should answer the PreToolUse event.'
Assert-True ($kubectlDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'A Secret dump should be denied before it runs.'
Assert-True ($kubectlDecision.hookSpecificOutput.permissionDecisionReason -match 'describe secret') 'The kubectl reason should name the key-name alternative.'
Assert-True ($kubectlDecision.hookSpecificOutput.permissionDecisionReason -match 'sha256sum') 'The kubectl reason should name the hash alternative.'

$azDecision = (Invoke-Guard (New-Payload 'PowerShell' ([ordered]@{ command = 'az keyvault secret show --vault-name kv -n db-password' }))) | ConvertFrom-Json
Assert-True ($azDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'A Key Vault secret read should be denied in the PowerShell tool.'
Assert-True ($azDecision.hookSpecificOutput.permissionDecisionReason -match '--query') 'The az reason should name the metadata query alternative.'

$glabDecision = (Invoke-Guard (New-Payload 'Bash' ([ordered]@{ command = 'glab api projects/123/variables | head' }))) | ConvertFrom-Json
Assert-True ($glabDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'A variables API read should be denied.'
Assert-True ($glabDecision.hookSpecificOutput.permissionDecisionReason -match '\.key') 'The glab reason should name the keys-only alternative.'

$stringInputDecision = (Invoke-Guard (New-Payload 'Bash' 'kubectl get secret app -o json')) | ConvertFrom-Json
Assert-True ($stringInputDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'A tool input given as a plain command string should be inspected.'

$vectorDecision = (Invoke-Guard (New-Payload 'Bash' ([ordered]@{ command = @('bash', '-lc', 'kubectl get secret app -o yaml') }))) | ConvertFrom-Json
Assert-True ($vectorDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'A tool input given as an argument vector should be inspected.'

foreach ($allowed in @('kubectl get secret app', 'git status', 'kubectl get secret app -o json | sha256sum')) {
    $allowedOutput = Invoke-Guard (New-Payload 'Bash' ([ordered]@{ command = $allowed }))
    Assert-True ([string]::IsNullOrWhiteSpace($allowedOutput)) "The guard should stay silent for an allowed command: $allowed"
}

$noCommandOutput = Invoke-Guard (New-Payload 'Bash' ([ordered]@{ description = 'no command' }))
Assert-True ([string]::IsNullOrWhiteSpace($noCommandOutput)) 'A payload without a command should pass silently.'

$malformedOutput = (Invoke-Guard '{not valid json') | ConvertFrom-Json
Assert-True ($malformedOutput.systemMessage -match 'failed open') 'A malformed payload should fail open with a warning.'
Assert-True ($malformedOutput.PSObject.Properties.Name -notcontains 'hookSpecificOutput') 'A malformed payload must not produce a denial.'

[pscustomobject]@{
    result = 'passed'
    assertions = $assertionCount
} | ConvertTo-Json
