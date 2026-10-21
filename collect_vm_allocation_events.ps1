[CmdletBinding()]
param(
    [Parameter()]
    [string[]] $Subscriptions,

    [Parameter()]
    [ValidateRange(1, 89)]
    [int] $LookbackDays = 30,

    [Parameter()]
    [ValidateRange(1, 16)]
    [int] $Concurrency = 4,

    [Parameter()]
    [string] $OutputDirectory = (Join-Path $PWD ("vm-allocation-events-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [Parameter()]
    [switch] $NoZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:CollectorVersion = "1.0.0"
$script:AzIsBatch = $null

$script:OperationNames = @(
    "microsoft.compute/virtualmachines/write",
    "microsoft.compute/virtualmachines/start/action",
    "microsoft.compute/virtualmachines/redeploy/action",
    "microsoft.compute/virtualmachines/restart/action"
)

function Write-Section {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Check {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter()][scriptblock] $StatusAction
    )

    if ($null -eq $script:AzIsBatch) {
        $azCommand = Get-Command az -ErrorAction SilentlyContinue
        $script:AzIsBatch = ($null -ne $azCommand) -and ($azCommand.Source -match '\.(cmd|bat)$')
    }
    $safeArguments = @(
        foreach ($argument in $Arguments) {
            $text = [string]$argument
            if ($script:AzIsBatch -and $text -match '[&|<>^]' -and $text -notmatch '\s') {
                '"' + $text + '"'
            }
            else { $text }
        }
    )

    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        for ($attempt = 1; ; $attempt++) {
            $output = & az @safeArguments --only-show-errors --output json 2> $stderrPath
            if ($LASTEXITCODE -eq 0) { break }
            $detail = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue).Trim()
            $isRetryable = $detail -match (
                "Too Many Requests|\b429\b|\b50[0234]\b|timed? ?out|timeout|" +
                "temporarily unavailable|connection (?:aborted|reset|refused)|" +
                "failed to establish a new connection|Max retries exceeded|WinError 10013"
            )
            if ($attempt -lt 5 -and $isRetryable) {
                $delay = [math]::Pow(2, $attempt) * 5
                $message = "Transient Azure CLI failure. Retrying in $delay seconds."
                if ($StatusAction) {
                    & $StatusAction $message
                }
                else {
                    Write-Host "  $message"
                }
                Start-Sleep -Seconds $delay
                continue
            }
            throw "Azure CLI failed: az $($Arguments -join ' ')`n$detail"
        }
        $text = ($output -join [Environment]::NewLine).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return $text | ConvertFrom-Json
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Export-JsonArray {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Data,
        [Parameter(Mandatory)][string] $Path
    )
    ConvertTo-Json -InputObject @($Data) -Depth 50 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-NormalizedList {
    param([string[]] $Values)
    return @(
        $Values |
            ForEach-Object { $_ -split "," } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Get-PropertyValue {
    param(
        [Parameter()][AllowNull()][object] $InputObject,
        [Parameter(Mandatory)][string] $Name
    )
    if ($null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }
    return $null
}

function Get-DisplayValue {
    param([Parameter()][AllowNull()][object] $InputObject)

    if ($null -eq $InputObject) { return $null }
    $value = Get-PropertyValue -InputObject $InputObject -Name "value"
    if ($null -ne $value) { return [string]$value }
    return [string]$InputObject
}

function Get-OperationCategory {
    param([Parameter(Mandatory)][string] $OperationName)

    switch ($OperationName.ToLowerInvariant()) {
        "microsoft.compute/virtualmachines/write" { return "createOrUpdate" }
        "microsoft.compute/virtualmachines/start/action" { return "start" }
        "microsoft.compute/virtualmachines/redeploy/action" { return "redeploy" }
        "microsoft.compute/virtualmachines/restart/action" { return "restart" }
        default { return "other" }
    }
}

function Get-FailureDetail {
    param([Parameter()][AllowNull()][object] $Properties)

    $reason = $null
    $message = $null
    $statusMessage = Get-PropertyValue -InputObject $Properties -Name "statusMessage"
    if ($statusMessage) {
        $payload = $statusMessage
        if ($statusMessage -is [string]) {
            try {
                $payload = $statusMessage | ConvertFrom-Json
            }
            catch {
                $payload = $null
                $message = [string]$statusMessage
            }
        }

        if ($null -ne $payload) {
            $errorObject = Get-PropertyValue -InputObject $payload -Name "error"
            if ($null -eq $errorObject) { $errorObject = $payload }
            $details = @(Get-PropertyValue -InputObject $errorObject -Name "details")
            $detail = $details | Where-Object { $null -ne $_ } | Select-Object -First 1
            $reason = if ($detail) {
                Get-PropertyValue -InputObject $detail -Name "code"
            }
            else {
                Get-PropertyValue -InputObject $errorObject -Name "code"
            }
            $message = if ($detail) {
                Get-PropertyValue -InputObject $detail -Name "message"
            }
            else {
                Get-PropertyValue -InputObject $errorObject -Name "message"
            }
        }
    }

    return [pscustomobject][ordered]@{
        reason = if ($null -ne $reason) { [string]$reason } else { $null }
        message = if ($null -ne $message) { [string]$message } else { $null }
    }
}

function ConvertTo-AllocationEventRecord {
    param(
        [Parameter(Mandatory)][object] $Event,
        [Parameter(Mandatory)][string] $SubscriptionId
    )

    $resourceId = [string](Get-PropertyValue -InputObject $Event -Name "resourceId")
    if ([string]::IsNullOrWhiteSpace($resourceId)) {
        $resourceId = [string](Get-PropertyValue -InputObject $Event -Name "resourceUri")
    }
    if ($resourceId -notmatch '(?i)^/subscriptions/[^/]+/resourcegroups/([^/]+)/providers/microsoft\.compute/virtualmachines/([^/]+)$') {
        return $null
    }
    $resourceGroup = $Matches[1]
    $vmName = $Matches[2]

    $operationName = Get-DisplayValue (Get-PropertyValue -InputObject $Event -Name "operationName")
    if (
        [string]::IsNullOrWhiteSpace($operationName) -or
        $script:OperationNames -notcontains $operationName.ToLowerInvariant()
    ) {
        return $null
    }

    $status = Get-DisplayValue (Get-PropertyValue -InputObject $Event -Name "status")
    $subStatus = Get-DisplayValue (Get-PropertyValue -InputObject $Event -Name "subStatus")
    $properties = Get-PropertyValue -InputObject $Event -Name "properties"
    $failure = if ([string]$status -and $status.ToLowerInvariant() -eq "failed") {
        Get-FailureDetail -Properties $properties
    }
    else {
        [pscustomobject]@{ reason = $null; message = $null }
    }

    return [pscustomobject][ordered]@{
        id = $resourceId.ToLowerInvariant()
        subscriptionId = $SubscriptionId
        resourceGroup = $resourceGroup
        name = $vmName
        eventTimestamp = Get-PropertyValue -InputObject $Event -Name "eventTimestamp"
        submissionTimestamp = Get-PropertyValue -InputObject $Event -Name "submissionTimestamp"
        operationName = $operationName
        operationCategory = Get-OperationCategory -OperationName $operationName
        status = $status
        subStatus = $subStatus
        correlationId = Get-PropertyValue -InputObject $Event -Name "correlationId"
        caller = Get-PropertyValue -InputObject $Event -Name "caller"
        eventDataId = Get-PropertyValue -InputObject $Event -Name "eventDataId"
        reason = $failure.reason
        message = $failure.message
        properties = $properties
    }
}

function Get-SubscriptionAllocationEventRecords {
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To,
        [Parameter(Mandatory)][object] $MessageQueue
    )

    $filter = (
        "eventTimestamp ge '$($From.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))' and " +
        "eventTimestamp le '$($To.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))' and " +
        "resourceProvider eq 'Microsoft.Compute'"
    )
    $encodedFilter = [uri]::EscapeDataString($filter)
    $nextUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/microsoft.insights/eventtypes/management/values?api-version=2015-04-01&`$filter=$encodedFilter"
    $page = 0
    $recordCount = 0
    $statusAction = {
        param([string] $Message)
        [void]$MessageQueue.Enqueue([pscustomobject][ordered]@{
            kind = "status"
            subscriptionId = $SubscriptionId
            message = $Message
        })
    }.GetNewClosure()

    while ($nextUrl) {
        $page++
        $response = Invoke-AzJson -Arguments @("rest", "--method", "get", "--url", $nextUrl) -StatusAction $statusAction
        foreach ($event in @($response.value)) {
            $record = ConvertTo-AllocationEventRecord -Event $event -SubscriptionId $SubscriptionId
            if ($null -ne $record) {
                [void]$MessageQueue.Enqueue([pscustomobject][ordered]@{
                    kind = "record"
                    subscriptionId = $SubscriptionId
                    record = $record
                })
                $recordCount++
            }
        }
        [void]$MessageQueue.Enqueue([pscustomobject][ordered]@{
            kind = "page"
            subscriptionId = $SubscriptionId
            page = $page
            records = $recordCount
        })
        $nextUrl = if ($response.PSObject.Properties.Name -contains "nextLink") {
            $response.nextLink
        }
        else { $null }
    }
    return $recordCount
}

function Get-AllocationEventSummaries {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Records)

    $summaries = [System.Collections.Generic.List[object]]::new()
    $groups = @(
        $Records |
            Group-Object -Property {
                $correlationKey = if ([string]::IsNullOrWhiteSpace([string]$_.correlationId)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$_.eventDataId)) {
                        [string]$_.eventDataId
                    }
                    else {
                        [string]$_.eventTimestamp
                    }
                }
                else {
                    [string]$_.correlationId
                }
                "{0}|{1}|{2}" -f (
                    [string]$_.id
                ).ToLowerInvariant(), (
                    [string]$_.operationName
                ).ToLowerInvariant(), $correlationKey.ToLowerInvariant()
            }
    )

    foreach ($group in $groups) {
        $events = @($group.Group | Sort-Object -Property eventTimestamp, submissionTimestamp, eventDataId)
        $startedEvents = @($events | Where-Object { ([string]$_.status).ToLowerInvariant() -eq "started" })
        $acceptedEvents = @($events | Where-Object { ([string]$_.status).ToLowerInvariant() -eq "accepted" })
        $terminalEvents = @(
            $events | Where-Object {
                @("succeeded", "failed") -contains ([string]$_.status).ToLowerInvariant()
            }
        )
        $firstEvent = $events[0]
        $startedEvent = $startedEvents | Select-Object -First 1
        $finalEvent = $terminalEvents | Select-Object -Last 1
        $correlationState = if ($terminalEvents.Count -gt 1) {
            "multipleTerminal"
        }
        elseif ($startedEvents.Count -gt 0 -and $terminalEvents.Count -eq 1) {
            "complete"
        }
        elseif ($startedEvents.Count -eq 0 -and $terminalEvents.Count -eq 1) {
            "terminalOnly"
        }
        else {
            "incomplete"
        }

        $reason = if ($null -ne $finalEvent) { $finalEvent.reason } else { "No final event found" }
        $message = if ($null -ne $finalEvent) { $finalEvent.message } else { $null }
        if ($terminalEvents.Count -gt 1 -and [string]::IsNullOrWhiteSpace([string]$reason)) {
            $reason = "Multiple final events found"
        }

        $summaries.Add([pscustomobject][ordered]@{
            id = $firstEvent.id
            subscriptionId = $firstEvent.subscriptionId
            resourceGroup = $firstEvent.resourceGroup
            name = $firstEvent.name
            eventTimestamp = if ($null -ne $startedEvent) { $startedEvent.eventTimestamp } else { $firstEvent.eventTimestamp }
            finalTimestamp = if ($null -ne $finalEvent) { $finalEvent.eventTimestamp } else { $null }
            operationName = $firstEvent.operationName
            operationCategory = $firstEvent.operationCategory
            correlationId = $firstEvent.correlationId
            caller = if ($null -ne $startedEvent) { $startedEvent.caller } else { $firstEvent.caller }
            status = if ($null -ne $finalEvent) { $finalEvent.status } else { "Unknown" }
            reason = $reason
            message = $message
            correlationState = $correlationState
            recordCount = $events.Count
            startedCount = $startedEvents.Count
            acceptedCount = $acceptedEvents.Count
            terminalCount = $terminalEvents.Count
        })
    }

    return @(
        $summaries.ToArray() |
            Sort-Object -Property id, eventTimestamp, operationName, correlationId
    )
}

function Invoke-SubscriptionAllocationEventCollection {
    param(
        [Parameter(Mandatory)][string[]] $SubscriptionIds,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To,
        [Parameter(Mandatory)][ValidateRange(1, 16)][int] $WorkerLimit
    )

    $workerCount = [math]::Min($WorkerLimit, $SubscriptionIds.Count)
    $selectedOperationNames = @($script:OperationNames)
    Write-Host "  Activity Logs: using $workerCount worker(s) across $($SubscriptionIds.Count) subscription(s)."

    $functionDefinitions = @"
function Invoke-AzJson {
$(${function:Invoke-AzJson}.ToString())
}
function Get-PropertyValue {
$(${function:Get-PropertyValue}.ToString())
}
function Get-DisplayValue {
$(${function:Get-DisplayValue}.ToString())
}
function Get-OperationCategory {
$(${function:Get-OperationCategory}.ToString())
}
function Get-FailureDetail {
$(${function:Get-FailureDetail}.ToString())
}
function ConvertTo-AllocationEventRecord {
$(${function:ConvertTo-AllocationEventRecord}.ToString())
}
function Get-SubscriptionAllocationEventRecords {
$(${function:Get-SubscriptionAllocationEventRecords}.ToString())
}
"@
    $workerScript = {
        param(
            [Parameter(Mandatory)][string] $SubscriptionId,
            [Parameter(Mandatory)][datetime] $From,
            [Parameter(Mandatory)][datetime] $To,
            [Parameter(Mandatory)][object] $MessageQueue,
            [Parameter(Mandatory)][string] $FunctionDefinitions,
            [Parameter(Mandatory)][string[]] $OperationNames
        )

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"
        $script:AzIsBatch = $null
        $script:OperationNames = $OperationNames
        . ([scriptblock]::Create($FunctionDefinitions))

        try {
            $recordCount = Get-SubscriptionAllocationEventRecords `
                -SubscriptionId $SubscriptionId -From $From -To $To -MessageQueue $MessageQueue
            [void]$MessageQueue.Enqueue([pscustomobject][ordered]@{
                kind = "completed"
                subscriptionId = $SubscriptionId
                records = $recordCount
            })
        }
        catch {
            [void]$MessageQueue.Enqueue([pscustomobject][ordered]@{
                kind = "failed"
                subscriptionId = $SubscriptionId
                error = $_.Exception.Message
            })
        }
    }

    $messageQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $workerCount)
    $workers = [System.Collections.Generic.List[object]]::new()
    $records = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()
    $nextSubscriptionIndex = 0
    $completedSubscriptionCount = 0
    $runspacePool.Open()

    try {
        $startWorker = {
            param([Parameter(Mandatory)][string] $SubscriptionId)

            $powerShell = [powershell]::Create()
            $powerShell.RunspacePool = $runspacePool
            [void]$powerShell.AddScript($workerScript)
            [void]$powerShell.AddArgument($SubscriptionId)
            [void]$powerShell.AddArgument($From)
            [void]$powerShell.AddArgument($To)
            [void]$powerShell.AddArgument($messageQueue)
            [void]$powerShell.AddArgument($functionDefinitions)
            [void]$powerShell.AddArgument($selectedOperationNames)
            return [pscustomobject][ordered]@{
                subscriptionId = $SubscriptionId
                powerShell = $powerShell
                handle = $powerShell.BeginInvoke()
            }
        }.GetNewClosure()

        while ($nextSubscriptionIndex -lt $workerCount) {
            $workers.Add((& $startWorker $SubscriptionIds[$nextSubscriptionIndex]))
            $nextSubscriptionIndex++
        }

        while ($workers.Count -gt 0) {
            $message = $null
            while ($messageQueue.TryDequeue([ref]$message)) {
                switch ($message.kind) {
                    "record" {
                        $records.Add($message.record)
                    }
                    "page" {
                        Write-Host "  Activity Logs: $($message.subscriptionId) page $($message.page), $($message.records) matching record(s)."
                    }
                    "status" {
                        Write-Host "  $($message.message) Subscription: $($message.subscriptionId)."
                    }
                    "completed" {
                        $completedSubscriptionCount++
                        Write-Host "  Activity Logs: completed $completedSubscriptionCount/$($SubscriptionIds.Count) subscriptions; $($message.records) matching record(s) in $($message.subscriptionId)."
                    }
                    "failed" {
                        $completedSubscriptionCount++
                        $errors.Add([pscustomobject][ordered]@{
                            subscriptionId = $message.subscriptionId
                            error = $message.error
                        })
                        Write-Warning "Activity Log collection failed for $($message.subscriptionId): $($message.error)"
                    }
                }
                $message = $null
            }

            foreach ($worker in @($workers)) {
                if ($worker.handle.IsCompleted) {
                    try {
                        [void]$worker.powerShell.EndInvoke($worker.handle)
                        if ($worker.powerShell.HadErrors) {
                            $workerError = @($worker.powerShell.Streams.Error) | Select-Object -First 1
                            throw "Activity Log worker failed for subscription $($worker.subscriptionId): $workerError"
                        }
                    }
                    finally {
                        $worker.powerShell.Dispose()
                        [void]$workers.Remove($worker)
                    }
                    if ($nextSubscriptionIndex -lt $SubscriptionIds.Count) {
                        $workers.Add((& $startWorker $SubscriptionIds[$nextSubscriptionIndex]))
                        $nextSubscriptionIndex++
                    }
                }
            }

            if ($workers.Count -gt 0) {
                Start-Sleep -Milliseconds 200
            }
        }

        $message = $null
        while ($messageQueue.TryDequeue([ref]$message)) {
            switch ($message.kind) {
                "record" { $records.Add($message.record) }
                "completed" {
                    $completedSubscriptionCount++
                    Write-Host "  Activity Logs: completed $completedSubscriptionCount/$($SubscriptionIds.Count) subscriptions; $($message.records) matching record(s) in $($message.subscriptionId)."
                }
                "failed" {
                    $completedSubscriptionCount++
                    $errors.Add([pscustomobject][ordered]@{
                        subscriptionId = $message.subscriptionId
                        error = $message.error
                    })
                    Write-Warning "Activity Log collection failed for $($message.subscriptionId): $($message.error)"
                }
                "page" {
                    Write-Host "  Activity Logs: $($message.subscriptionId) page $($message.page), $($message.records) matching record(s)."
                }
                "status" {
                    Write-Host "  $($message.message) Subscription: $($message.subscriptionId)."
                }
            }
            $message = $null
        }
    }
    finally {
        foreach ($worker in @($workers)) {
            try {
                $worker.powerShell.Stop()
            }
            finally {
                $worker.powerShell.Dispose()
            }
        }
        $runspacePool.Close()
        $runspacePool.Dispose()
    }

    return [pscustomobject][ordered]@{
        records = @(
            $records.ToArray() |
                Sort-Object -Property id, eventTimestamp, operationName, correlationId, status
        )
        errors = $errors.ToArray()
    }
}

Write-Host "VM allocation-event collector $script:CollectorVersion" -ForegroundColor Green
Write-Section "Checking prerequisites"

if ($PSVersionTable.PSVersion -lt [version]"5.1") {
    throw "PowerShell 5.1 or later is required. Detected $($PSVersionTable.PSVersion)."
}
Write-Check "PowerShell $($PSVersionTable.PSVersion)"

$azCommand = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCommand) {
    throw "Azure CLI was not found. Install it from https://aka.ms/installazurecliwindows and run 'az login'."
}
Write-Check "Azure CLI found at $($azCommand.Source)"

try {
    $azVersion = Invoke-AzJson -Arguments @("version")
    Write-Check "Azure CLI $($azVersion.'azure-cli')"
}
catch {
    throw "Azure CLI could not be started. Reinstall or repair Azure CLI and retry.`n$($_.Exception.Message)"
}

try {
    $account = Invoke-AzJson -Arguments @("account", "show")
}
catch {
    throw "Azure CLI authentication check failed. Run 'az login --tenant <tenant-id>' and retry.`n$($_.Exception.Message)"
}
if (-not $account -or -not $account.tenantId) {
    throw "No active Azure CLI session. Run 'az login' and retry."
}
Write-Check "Azure CLI authenticated to tenant $($account.tenantId)"

try {
    $availableAccounts = @(Invoke-AzJson -Arguments @("account", "list", "--all"))
}
catch {
    throw "Azure CLI could not list accessible subscriptions. Run 'az login --tenant $($account.tenantId)' and retry.`n$($_.Exception.Message)"
}

$subscriptionIds = @(Get-NormalizedList -Values $Subscriptions)
if ($subscriptionIds.Count -eq 0) {
    $subscriptionIds = @(
        $availableAccounts |
            Where-Object {
                ([string]$_.state).Equals("Enabled", [System.StringComparison]::OrdinalIgnoreCase) -and
                ([string]$_.tenantId).Equals([string]$account.tenantId, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            ForEach-Object { [string]$_.id }
    )
}
if ($subscriptionIds.Count -eq 0) {
    throw "No enabled subscriptions were found in tenant $($account.tenantId) for the signed-in identity."
}

$accountBySubscriptionId = @{}
foreach ($availableAccount in $availableAccounts) {
    $accountBySubscriptionId[([string]$availableAccount.id).ToLowerInvariant()] = $availableAccount
}
$unavailableSubscriptionIds = @(
    $subscriptionIds | Where-Object {
        -not $accountBySubscriptionId.ContainsKey(([string]$_).ToLowerInvariant())
    }
)
if ($unavailableSubscriptionIds.Count -gt 0) {
    throw "The signed-in identity cannot access these subscriptions: $($unavailableSubscriptionIds -join ', ')."
}
$invalidSubscriptionIds = @(
    $subscriptionIds | Where-Object {
        $selectedAccount = $accountBySubscriptionId[([string]$_).ToLowerInvariant()]
        -not ([string]$selectedAccount.state).Equals("Enabled", [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$selectedAccount.tenantId).Equals([string]$account.tenantId, [System.StringComparison]::OrdinalIgnoreCase)
    }
)
if ($invalidSubscriptionIds.Count -gt 0) {
    throw "These subscriptions are disabled or outside active tenant $($account.tenantId): $($invalidSubscriptionIds -join ', ')."
}
Write-Check "Access to $($subscriptionIds.Count) enabled subscriptions in the active tenant"

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
$zipPath = "$outputRoot.zip"
if (Test-Path -LiteralPath $outputRoot) {
    throw "Output directory already exists: $outputRoot"
}
if (-not $NoZip -and (Test-Path -LiteralPath $zipPath)) {
    throw "Output ZIP already exists: $zipPath"
}

$to = [datetime]::UtcNow
$from = $to.AddDays(-$LookbackDays)
New-Item -ItemType Directory -Path $outputRoot | Out-Null

Write-Section "Collecting subscription-level VM allocation events"
Write-Host "Tenant: $($account.tenantId)"
Write-Host "Subscriptions: $($subscriptionIds.Count)"
Write-Host "Lookback: $LookbackDays day(s)"
Write-Host "Workers: $Concurrency"
Write-Host "From: $($from.ToString("o"))"
Write-Host "To: $($to.ToString("o"))"
Write-Host "Output: $outputRoot"

$collection = Invoke-SubscriptionAllocationEventCollection `
    -SubscriptionIds $subscriptionIds -From $from -To $to -WorkerLimit $Concurrency
$records = @($collection.records)
$summaries = @(Get-AllocationEventSummaries -Records $records)

Export-JsonArray -Data $records -Path (Join-Path $outputRoot "allocation_event_records.json")
Export-JsonArray -Data $summaries -Path (Join-Path $outputRoot "allocation_events.json")

$sectionStatus = if ($collection.errors.Count -eq 0) {
    "succeeded"
}
elseif ($collection.errors.Count -lt $subscriptionIds.Count) {
    "partial"
}
else {
    "failed"
}
$manifest = [ordered]@{
    schemaVersion = 1
    collectorVersion = $script:CollectorVersion
    collectionMode = "subscriptionAllocationEvents"
    collectedAtUtc = [datetime]::UtcNow.ToString("o")
    tenantId = $account.tenantId
    subscriptions = $subscriptionIds
    lookbackDays = $LookbackDays
    fromUtc = $from.ToString("o")
    toUtc = $to.ToString("o")
    concurrency = $Concurrency
    operations = $script:OperationNames
    sections = [ordered]@{
        allocationEventRecords = [ordered]@{
            status = $sectionStatus
            records = $records.Count
            failedSubscriptions = $collection.errors.Count
            errors = @($collection.errors)
        }
        allocationEvents = [ordered]@{
            status = $sectionStatus
            records = $summaries.Count
        }
    }
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $outputRoot "manifest.json") -Encoding utf8

if (-not $NoZip) {
    Write-Section "Creating transfer package"
    Compress-Archive -Path (Join-Path $outputRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "Package created: $zipPath" -ForegroundColor Green
}
else {
    Write-Host "Data collected: $outputRoot" -ForegroundColor Green
}

Write-Host "Collected $($records.Count) raw matching records and $($summaries.Count) correlated attempts."
if ($collection.errors.Count -gt 0) {
    Write-Warning "Collection completed with $($collection.errors.Count) failed subscription(s). Review manifest.json."
}
