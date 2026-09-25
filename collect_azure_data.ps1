[CmdletBinding()]
param(
    [Parameter()]
    [string[]] $Subscriptions,

    [Parameter()]
    [string[]] $Locations,

    [Parameter()]
    [ValidateRange(1, 365)]
    [int] $UptimeLookbackDays = 30,

    [Parameter()]
    [ValidateRange(1, 89)]
    [int] $AllocationLookbackDays = 30,

    [Parameter()]
    [string] $OutputDirectory = (Join-Path $PWD ("capacity-reservation-data-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [Parameter()]
    [switch] $SkipCost,

    [Parameter()]
    [switch] $SkipAllocationEvents,

    [Parameter()]
    [switch] $SkipAsr,

    [Parameter()]
    [switch] $SkipVmSizeInfo,

    [Parameter()]
    [switch] $SkipPhysicalZones,

    [Parameter()]
    [switch] $NoZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:CollectorVersion = "1.0.1"
$script:SectionStatus = [ordered]@{}
$script:AzIsBatch = $null

function Write-Section {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Arguments)

    # az ships as a .cmd shim on Windows, so cmd.exe re-parses the command line and
    # splits unquoted &, | and friends. Quote those arguments back up.
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
            if ($attempt -lt 5 -and $detail -match "Too Many Requests|\b429\b") {
                $delay = [math]::Pow(2, $attempt) * 5
                Write-Host "  Throttled by Azure. Retrying in $delay seconds."
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

function Get-GraphRows {
    param(
        [Parameter(Mandatory)][string] $Query,
        [Parameter(Mandatory)][string[]] $SubscriptionIds,
        [Parameter(Mandatory)][string] $ProgressName,
        [Parameter()][ValidateRange(0, 1000)][int] $SubscriptionBatchSize = 0
    )

    # The cmd.exe shim strips the quotes inside the KQL, so hand it to az as a file.
    $queryPath = [System.IO.Path]::GetTempFileName()
    Set-Content -LiteralPath $queryPath -Value $Query -Encoding utf8
    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        $effectiveBatchSize = if ($SubscriptionBatchSize -gt 0) {
            [math]::Min($SubscriptionBatchSize, $SubscriptionIds.Count)
        }
        else {
            $SubscriptionIds.Count
        }
        $batchCount = [math]::Ceiling($SubscriptionIds.Count / $effectiveBatchSize)

        for ($batchIndex = 0; $batchIndex -lt $batchCount; $batchIndex++) {
            $firstSubscriptionIndex = $batchIndex * $effectiveBatchSize
            $lastSubscriptionIndex = [math]::Min(
                $firstSubscriptionIndex + $effectiveBatchSize - 1,
                $SubscriptionIds.Count - 1
            )
            $currentSubscriptionIds = @($SubscriptionIds[$firstSubscriptionIndex..$lastSubscriptionIndex])
            $skip = 0
            $page = 1
            do {
                Write-Host (
                    "  {0}: batch {1}/{2}, subscriptions {3}-{4} of {5}, page {6}..." -f
                    $ProgressName,
                    ($batchIndex + 1),
                    $batchCount,
                    ($firstSubscriptionIndex + 1),
                    ($lastSubscriptionIndex + 1),
                    $SubscriptionIds.Count,
                    $page
                )
                $arguments = @(
                    "graph", "query", "--graph-query", "@$queryPath",
                    "--first", "1000", "--skip", "$skip", "--subscriptions"
                )
                $arguments += $currentSubscriptionIds
                $response = Invoke-AzJson -Arguments $arguments
                $pageRows = @(if ($null -ne $response -and $response.PSObject.Properties.Name -contains "data") {
                    @($response.data)
                }
                else {
                    @($response)
                })
                foreach ($row in $pageRows) {
                    if ($null -ne $row) {
                        $rows.Add($row)
                    }
                }
                $skip += $pageRows.Count
                Write-Host "    Received $($pageRows.Count) rows; $($rows.Count) total."
                $page++
            }
            while ($pageRows.Count -eq 1000)
        }
    }
    finally {
        Remove-Item -LiteralPath $queryPath -Force -ErrorAction SilentlyContinue
    }
    return $rows.ToArray()
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

function Get-ComputeQuotaUsage {
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $Location
    )

    $nextUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location/usages?api-version=2025-04-01"
    $usages = [System.Collections.Generic.List[object]]::new()
    while ($nextUrl) {
        $response = Invoke-AzJson -Arguments @("rest", "--method", "get", "--url", $nextUrl)
        if ($null -eq $response) { break }
        if ($response.PSObject.Properties.Name -contains "value") {
            foreach ($usage in @($response.value)) {
                if ($null -ne $usage) { $usages.Add($usage) }
            }
        }
        $nextUrl = if ($response.PSObject.Properties.Name -contains "nextLink") {
            $response.nextLink
        }
        else { $null }
    }

    return @(
        foreach ($usage in $usages) {
            $name = Get-PropertyValue -InputObject $usage -Name "name"
            $currentValue = Get-PropertyValue -InputObject $usage -Name "currentValue"
            $limit = Get-PropertyValue -InputObject $usage -Name "limit"
            [pscustomobject][ordered]@{
                subscription_id = $SubscriptionId
                location = $Location
                resource_name = [string](Get-PropertyValue -InputObject $name -Name "value")
                localized_name = [string](Get-PropertyValue -InputObject $name -Name "localizedValue")
                current_value = if ($null -ne $currentValue) { [int64]$currentValue } else { $null }
                limit = if ($null -ne $limit) { [int64]$limit } else { $null }
                unit = [string](Get-PropertyValue -InputObject $usage -Name "unit")
            }
        }
    )
}

function Invoke-OptionalSection {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][scriptblock] $Action
    )
    try {
        $result = & $Action
        $script:SectionStatus[$Name] = [ordered]@{ status = "succeeded"; records = @($result).Count }
        return @($result)
    }
    catch {
        Write-Warning "$Name collection failed: $($_.Exception.Message)"
        $script:SectionStatus[$Name] = [ordered]@{ status = "failed"; records = 0; error = $_.Exception.Message }
        return @()
    }
}

function Convert-CostResponseRows {
    param([Parameter(Mandatory)][object] $Response)
    $properties = $Response.properties
    $columnNames = @($properties.columns | ForEach-Object { $_.name })
    $converted = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($properties.rows)) {
        $item = [ordered]@{}
        for ($index = 0; $index -lt $columnNames.Count; $index++) {
            $item[$columnNames[$index]] = $row[$index]
        }
        $converted.Add([pscustomobject]$item)
    }
    return $converted.ToArray()
}

function Get-CostManagementRows {
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To,
        [Parameter(Mandatory)][ValidateSet("ActualCost", "AmortizedCost")][string] $CostType,
        [Parameter(Mandatory)][ValidateSet("Daily", "Monthly")][string] $Granularity,
        [Parameter(Mandatory)][ValidateSet("UsageQuantity", "Cost")][string] $Metric
    )

    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    $body = [ordered]@{
        type = $CostType
        timeframe = "Custom"
        timePeriod = [ordered]@{
            from = $From.ToUniversalTime().ToString("o")
            to = $To.ToUniversalTime().ToString("o")
        }
        dataset = [ordered]@{
            granularity = $Granularity
            aggregation = [ordered]@{
                $Metric = [ordered]@{ name = $Metric; function = "Sum" }
            }
            grouping = @([ordered]@{ type = "Dimension"; name = "ResourceId" })
            filter = [ordered]@{
                dimensions = [ordered]@{
                    name = "MeterCategory"
                    operator = "In"
                    values = @("Virtual Machines")
                }
            }
        }
    } | ConvertTo-Json -Depth 20 -Compress

    $rows = [System.Collections.Generic.List[object]]::new()
    # The compressed JSON body loses its quotes through the cmd.exe shim, so use az's @file syntax.
    $bodyPath = [System.IO.Path]::GetTempFileName()
    Set-Content -LiteralPath $bodyPath -Value $body -Encoding utf8
    try {
        $nextUrl = $url
        while ($nextUrl) {
            $response = Invoke-AzJson -Arguments @("rest", "--method", "post", "--url", $nextUrl, "--body", "@$bodyPath")
            foreach ($row in @(Convert-CostResponseRows -Response $response)) {
                $rows.Add($row)
            }
            $nextUrl = if ($response.properties.PSObject.Properties.Name -contains "nextLink") {
                $response.properties.nextLink
            }
            else { $null }
        }
    }
    finally {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
    }
    return $rows.ToArray()
}

function Get-ActivityLogEvents {
    param(
        [Parameter(Mandatory)][string] $VmId,
        [Parameter(Mandatory)][datetime] $From,
        [Parameter(Mandatory)][datetime] $To
    )

    $subscriptionId = $VmId.Split("/")[2]
    $filter = "eventTimestamp ge '$($From.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))' and eventTimestamp le '$($To.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))' and resourceUri eq '$VmId'"
    $encodedFilter = [uri]::EscapeDataString($filter)
    $nextUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/microsoft.insights/eventtypes/management/values?api-version=2015-04-01&`$filter=$encodedFilter"
    $events = [System.Collections.Generic.List[object]]::new()
    while ($nextUrl) {
        $response = Invoke-AzJson -Arguments @("rest", "--method", "get", "--url", $nextUrl)
        foreach ($event in @($response.value)) {
            $events.Add($event)
        }
        $nextUrl = if ($response.PSObject.Properties.Name -contains "nextLink") {
            $response.nextLink
        }
        else { $null }
    }
    return $events.ToArray()
}

function Convert-AllocationEvents {
    param(
        [Parameter(Mandatory)][string] $VmId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Events
    )

    $operationNames = @(
        "microsoft.compute/virtualmachines/start/action",
        "microsoft.compute/virtualmachines/poweroff/action",
        "microsoft.compute/virtualmachines/redeploy/action",
        "microsoft.compute/virtualmachines/restart/action",
        "microsoft.compute/virtualmachines/deallocate/action"
    )
    $curated = @(
        $Events | Where-Object {
            $null -ne $_.operationName -and
            $operationNames -contains ([string]$_.operationName.value).ToLowerInvariant()
        }
    )
    $summaries = [System.Collections.Generic.List[object]]::new()
    foreach ($started in @($curated | Where-Object { ([string]$_.status.value).ToLowerInvariant() -eq "started" })) {
        $finalEvents = @(
            $curated | Where-Object {
                $_.correlationId -eq $started.correlationId -and
                @("succeeded", "failed") -contains ([string]$_.status.value).ToLowerInvariant()
            }
        )
        $status = "Unknown"
        $reason = if ($finalEvents.Count -eq 0) { "No final event found" } elseif ($finalEvents.Count -gt 1) { "Multiple Final Events" } else { $null }
        $message = $null
        if ($finalEvents.Count -eq 1) {
            $status = [string]$finalEvents[0].status.value
            if ($status.ToLowerInvariant() -eq "failed") {
                $statusMessage = $finalEvents[0].properties.statusMessage
                if ($statusMessage) {
                    try {
                        $errorPayload = $statusMessage | ConvertFrom-Json
                        $errorObject = $errorPayload.error
                        $detail = @($errorObject.details) | Select-Object -First 1
                        $reason = if ($detail -and $detail.code) { $detail.code } else { $errorObject.code }
                        $message = if ($detail -and $detail.message) { $detail.message } else { $errorObject.message }
                    }
                    catch {
                        $message = [string]$statusMessage
                    }
                }
            }
        }
        $summaries.Add([pscustomobject][ordered]@{
            id = $VmId.ToLowerInvariant()
            eventTimestamp = $started.eventTimestamp
            operationName = $started.operationName.value
            correlationId = $started.correlationId
            caller = $started.caller
            status = $status
            reason = $reason
            message = $message
        })
    }
    return $summaries.ToArray()
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI was not found. Install it from https://aka.ms/installazurecliwindows and run 'az login'."
}

$account = Invoke-AzJson -Arguments @("account", "show")
if (-not $account) {
    throw "No active Azure CLI session. Run 'az login' and retry."
}

$subscriptionIds = @(Get-NormalizedList -Values $Subscriptions)
if ($subscriptionIds.Count -eq 0) {
    $subscriptionIds = @(
        Invoke-AzJson -Arguments @("account", "list", "--query", "[?state=='Enabled'].id") |
            ForEach-Object { [string]$_ }
    )
}
if ($subscriptionIds.Count -eq 0) {
    throw "No enabled subscriptions were found for the signed-in identity."
}

$locationIds = @(Get-NormalizedList -Values $Locations)
foreach ($location in $locationIds) {
    if ($location -notmatch "^[a-zA-Z0-9-]+$") {
        throw "Invalid Azure location '$location'. Use ARM names such as eastus or westeurope."
    }
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputRoot) {
    throw "Output directory already exists: $outputRoot"
}
New-Item -ItemType Directory -Path $outputRoot | Out-Null

Write-Host "Azure capacity-reservation data collector $script:CollectorVersion" -ForegroundColor Green
Write-Host "Tenant: $($account.tenantId)"
Write-Host "Subscriptions: $($subscriptionIds.Count)"
Write-Host "Locations: $(if ($locationIds.Count) { $locationIds -join ', ' } else { 'all' })"
Write-Host "Output: $outputRoot"

$locationClause = if ($locationIds.Count) {
    $quotedLocations = $locationIds | ForEach-Object { '"' + $_ + '"' }
    "| where location in~ ($($quotedLocations -join ', '))"
}
else { "" }

Write-Section "Collecting VM inventory"
$vmQuery = @"
resources
| where type =~ "microsoft.compute/virtualmachines"
$locationClause
| extend zone = tostring(zones[0])
| extend vmSize = tostring(properties.hardwareProfile.vmSize)
| extend isPartOfVMSSFlexible = iif(isnull(properties.virtualMachineScaleSet), "No", "Yes")
| extend capacityReservationGroup = tostring(properties.capacityReservation.capacityReservationGroup.id)
| extend vmTags = tags
| extend _rgId = tolower(strcat('/subscriptions/', subscriptionId, '/resourcegroups/', resourceGroup))
| join kind=leftouter (
    resourcecontainers
    | where type =~ "microsoft.resources/subscriptions/resourcegroups"
    | project _rgId = tolower(id), resourceGroupTags = tags
) on _rgId
| join kind=leftouter (
    resourcecontainers
    | where type =~ "microsoft.resources/subscriptions"
    | project subscriptionId, subscriptionName = name, subscriptionTags = tags
) on subscriptionId
| project id=tolower(id), subscriptionId, subscriptionName, subscriptionTags,
    resourceGroup, resourceGroupTags, name, location, zone, vmSize,
    isPartOfVMSSFlexible, capacityReservationGroup, vmTags
| order by id asc
"@
$vms = @(
    Get-GraphRows -Query $vmQuery -SubscriptionIds $subscriptionIds `
        -ProgressName "VM inventory" -SubscriptionBatchSize 10 |
        Sort-Object -Property id
)
if ($vms.Count -eq 0) {
    throw "No VMs were returned. Check subscription scope, locations, and Azure Resource Graph permissions."
}
Export-JsonArray -Data $vms -Path (Join-Path $outputRoot "vms.json")
$script:SectionStatus["vms"] = [ordered]@{ status = "succeeded"; records = $vms.Count }
Write-Host "Collected $($vms.Count) VMs."

Write-Section "Collecting capacity reservations"
$reservationQuery = @"
resources
| where type =~ "microsoft.compute/capacityreservationgroups"
$locationClause
| mv-expand capacityReservationId = properties.capacityReservations
| extend capacityReservationId = tolower(tostring(capacityReservationId.id))
| extend capacityReservationGroupZones = zones
| extend capacityReservationGroupId = tolower(id)
| extend capacityReservationGroupName = name
| project capacityReservationGroupId, capacityReservationGroupName,
    capacityReservationGroupZones, capacityReservationId, resourceGroup,
    subscriptionId, location
| join kind=leftouter (
    resources
    | where type =~ "microsoft.compute/capacityreservationgroups/capacityreservations"
    | mv-expand zone = zones
    | extend zone=tostring(zone), vmSize=tostring(sku.name), capacity=toint(sku.capacity)
    | extend provisioningState=tostring(properties.provisioningState)
    | extend timeCreated=tostring(properties.timeCreated)
    | extend provisioningTime=tostring(properties.provisioningTime)
    | extend platformFaultDomainCount=toint(properties.platformFaultDomainCount)
    | extend reservationId=tostring(properties.reservationId), id=tolower(id)
    | project id, name, zone, vmSize, capacity, provisioningState, timeCreated,
        provisioningTime, platformFaultDomainCount, reservationId
) on `$left.capacityReservationId == `$right.id
| project id, name, subscriptionId, resourceGroup, location, zone, vmSize,
    capacity, provisioningState, timeCreated, provisioningTime,
    platformFaultDomainCount, reservationId, capacityReservationGroupId,
    capacityReservationGroupName, capacityReservationGroupZones
| order by capacityReservationGroupId asc, id asc, zone asc
"@
$reservations = @(
    Get-GraphRows -Query $reservationQuery -SubscriptionIds $subscriptionIds `
        -ProgressName "Capacity reservations" -SubscriptionBatchSize 10 |
        Sort-Object -Property capacityReservationGroupId, id, zone
)
Export-JsonArray -Data $reservations -Path (Join-Path $outputRoot "capacity_reservations.json")
$script:SectionStatus["capacityReservations"] = [ordered]@{ status = "succeeded"; records = $reservations.Count }
Write-Host "Collected $($reservations.Count) capacity-reservation rows."

Write-Section "Collecting Azure Site Recovery data"
$asrRows = @(if ($SkipAsr) {
    $script:SectionStatus["asr"] = [ordered]@{ status = "skipped"; records = 0 }
    @()
}
else {
    Invoke-OptionalSection -Name "asr" -Action {
        $asrQuery = @"
recoveryservicesresources
| where type =~ "microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems"
| where properties.providerSpecificDetails.instanceType =~ "A2A"
| extend targetResourceGroupId=tolower(tostring(properties.providerSpecificDetails.recoveryAzureResourceGroupId))
| extend targetSubscriptionId=tostring(split(targetResourceGroupId, '/')[2])
| join kind=leftouter (
    resourcecontainers
    | where type =~ "microsoft.resources/subscriptions"
    | project targetSubscriptionId=subscriptionId, targetSubscriptionName=name
) on targetSubscriptionId
| project sourceVmId=tolower(tostring(properties.providerSpecificDetails.fabricObjectId)),
    targetVmName=tostring(properties.providerSpecificDetails.recoveryAzureVMName),
    targetResourceGroupId, targetSubscriptionId, targetSubscriptionName,
    targetCapacityReservationGroupId=tostring(properties.providerSpecificDetails.recoveryCapacityReservationGroupId),
    targetRegion=tostring(properties.providerSpecificDetails.recoveryFabricLocation),
    targetZone=tostring(properties.providerSpecificDetails.recoveryAvailabilityZone),
    protectionState=tostring(properties.protectionState),
    replicationHealth=tostring(properties.replicationHealth),
    targetVmSize=tostring(properties.providerSpecificDetails.recoveryAzureVMSize)
| order by sourceVmId asc, targetVmName asc
"@
        Get-GraphRows -Query $asrQuery -SubscriptionIds $subscriptionIds -ProgressName "Azure Site Recovery"
    }
})
$vmIdSet = @{}; foreach ($vm in $vms) { $vmIdSet[[string]$vm.id] = $true }
$asrRows = @($asrRows | Where-Object {
    $_.PSObject.Properties.Name -contains "sourceVmId" -and
    $vmIdSet.ContainsKey(([string]$_.sourceVmId).ToLowerInvariant())
})
Export-JsonArray -Data $asrRows -Path (Join-Path $outputRoot "asr.json")

$allSubscriptionIds = @(
    @($subscriptionIds) + @($asrRows | ForEach-Object { $_.targetSubscriptionId }) |
        Where-Object { $_ } | Select-Object -Unique
)
$allLocations = @(
    @($vms | ForEach-Object { $_.location }) + @($asrRows | ForEach-Object { $_.targetRegion }) |
        Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique
)

Write-Section "Collecting physical availability-zone mappings"
$physicalZones = @(if ($SkipPhysicalZones) {
    $script:SectionStatus["physicalZones"] = [ordered]@{ status = "skipped"; records = 0 }
    @()
}
else {
    Invoke-OptionalSection -Name "physicalZones" -Action {
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($subscriptionId in $allSubscriptionIds) {
            $url = "https://management.azure.com/subscriptions/$subscriptionId/locations?api-version=2022-12-01"
            $response = Invoke-AzJson -Arguments @("rest", "--method", "get", "--url", $url)
            foreach ($location in @($response.value | Where-Object { $allLocations -contains ([string]$_.name).ToLowerInvariant() })) {
                $zoneMappings = if ($location.PSObject.Properties.Name -contains "availabilityZoneMappings") {
                    @($location.availabilityZoneMappings)
                }
                else { @() }
                foreach ($mapping in $zoneMappings) {
                    $result.Add([pscustomobject][ordered]@{
                        subscription_id = $subscriptionId
                        location = $location.name
                        logical_zone = [string]$mapping.logicalZone
                        physical_zone = [string]$mapping.physicalZone
                    })
                }
            }
        }
        $result.ToArray()
    }
})
Export-JsonArray -Data $physicalZones -Path (Join-Path $outputRoot "physical_zones.json")

Write-Section "Collecting VM-size capabilities"
$vmSizeInfo = @(if ($SkipVmSizeInfo) {
    $script:SectionStatus["vmSizeInfo"] = [ordered]@{ status = "skipped"; records = 0 }
    @()
}
else {
    Invoke-OptionalSection -Name "vmSizeInfo" -Action {
        $result = [System.Collections.Generic.List[object]]::new()
        $catalogSubscription = $allSubscriptionIds[0]
        foreach ($location in $allLocations) {
            Write-Host "  VM SKUs: $location"
            $skus = @(Invoke-AzJson -Arguments @(
                "vm", "list-skus", "--subscription", $catalogSubscription,
                "--location", $location, "--resource-type", "virtualMachines", "--all", "true"
            ))
            foreach ($sku in $skus) {
                $capabilities = @{}
                foreach ($capability in @($sku.capabilities)) {
                    $capabilities[([string]$capability.name).ToLowerInvariant()] = $capability.value
                }
                $vcpuCount = $null
                if ($capabilities.ContainsKey("vcpus")) {
                    $parsedVcpu = 0
                    if ([int]::TryParse([string]$capabilities["vcpus"], [ref]$parsedVcpu)) { $vcpuCount = $parsedVcpu }
                }
                $crSupported = $capabilities.ContainsKey("capacityreservationsupported") -and
                    ([string]$capabilities["capacityreservationsupported"]).ToLowerInvariant() -eq "true"
                $result.Add([pscustomobject][ordered]@{
                    location = $location
                    vm_size = $sku.name
                    vm_family = $sku.family
                    vcpu_count = $vcpuCount
                    capacity_reservation_supported = $crSupported
                })
            }
        }
        $result.ToArray()
    }
})
Export-JsonArray -Data $vmSizeInfo -Path (Join-Path $outputRoot "vm_size_info.json")

Write-Section "Collecting Compute quota and usage"
$computeQuotaUsage = @(Invoke-OptionalSection -Name "computeQuotaUsage" -Action {
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($subscriptionId in $allSubscriptionIds) {
        foreach ($location in $allLocations) {
            Write-Host "  Compute quotas: $subscriptionId / $location"
            try {
                foreach ($row in @(Get-ComputeQuotaUsage -SubscriptionId $subscriptionId -Location $location)) {
                    $result.Add($row)
                }
            }
            catch {
                # A region can be unavailable to a subscription. Keep collecting the rest.
                Write-Warning "  Compute quotas unavailable for $subscriptionId / $location`: $($_.Exception.Message)"
            }
        }
    }
    $result.ToArray()
})
Export-JsonArray -Data $computeQuotaUsage -Path (Join-Path $outputRoot "compute_quota_usage.json")

$utcNow = [datetime]::UtcNow
$uptimeEnd = $utcNow.Date.AddTicks(-1)
$uptimeStart = $uptimeEnd.Date.AddDays(-($UptimeLookbackDays - 1))
Write-Section "Collecting Cost Management runtime and cost"
$uptimeDaily = @()
$uptimeCost = @()
if ($SkipCost) {
    $script:SectionStatus["cost"] = [ordered]@{ status = "skipped"; records = 0 }
}
else {
    try {
        $dailyList = [System.Collections.Generic.List[object]]::new()
        $costList = [System.Collections.Generic.List[object]]::new()
        foreach ($subscriptionId in $subscriptionIds) {
            Write-Host "  Cost Management: $subscriptionId"
            foreach ($row in @(Get-CostManagementRows -SubscriptionId $subscriptionId -From $uptimeStart -To $uptimeEnd -CostType ActualCost -Granularity Daily -Metric UsageQuantity)) {
                $dailyList.Add($row)
            }
            foreach ($row in @(Get-CostManagementRows -SubscriptionId $subscriptionId -From $uptimeStart -To $uptimeEnd -CostType AmortizedCost -Granularity Monthly -Metric Cost)) {
                $costList.Add($row)
            }
        }
        $uptimeDaily = $dailyList.ToArray()
        $uptimeCost = $costList.ToArray()
        $uptimeDaily = @(
            $uptimeDaily | Where-Object {
                $_.PSObject.Properties.Name -contains "ResourceId" -and
                $_.ResourceId -and $vmIdSet.ContainsKey(([string]$_.ResourceId).ToLowerInvariant())
            }
        )
        $uptimeCost = @(
            $uptimeCost | Where-Object {
                $_.PSObject.Properties.Name -contains "ResourceId" -and
                $_.ResourceId -and $vmIdSet.ContainsKey(([string]$_.ResourceId).ToLowerInvariant())
            }
        )
        $script:SectionStatus["cost"] = [ordered]@{
            status = "succeeded"
            records = $uptimeDaily.Count + $uptimeCost.Count
        }
    }
    catch {
        Write-Warning "Cost Management collection failed: $($_.Exception.Message)"
        $script:SectionStatus["cost"] = [ordered]@{ status = "failed"; records = 0; error = $_.Exception.Message }
    }
}
Export-JsonArray -Data $uptimeDaily -Path (Join-Path $outputRoot "uptime_daily.json")
Export-JsonArray -Data $uptimeCost -Path (Join-Path $outputRoot "uptime_cost.json")

Write-Section "Collecting VM allocation events"
$allocationRows = @()
if ($SkipAllocationEvents) {
    $script:SectionStatus["allocationEvents"] = [ordered]@{ status = "skipped"; records = 0 }
}
else {
    $allocationRows = @(Invoke-OptionalSection -Name "allocationEvents" -Action {
        $result = [System.Collections.Generic.List[object]]::new()
        $allocationFrom = $utcNow.AddDays(-$AllocationLookbackDays)
        for ($index = 0; $index -lt $vms.Count; $index++) {
            if (($index + 1) % 10 -eq 0 -or $index -eq 0 -or $index + 1 -eq $vms.Count) {
                Write-Host "  Activity Logs: $($index + 1)/$($vms.Count)"
            }
            $events = @(Get-ActivityLogEvents -VmId $vms[$index].id -From $allocationFrom -To $utcNow)
            foreach ($summary in @(Convert-AllocationEvents -VmId $vms[$index].id -Events $events)) {
                $result.Add($summary)
            }
        }
        $result.ToArray()
    })
}
Export-JsonArray -Data $allocationRows -Path (Join-Path $outputRoot "allocation_events.json")

$manifest = [ordered]@{
    schemaVersion = 1
    collectorVersion = $script:CollectorVersion
    collectedAtUtc = [datetime]::UtcNow.ToString("o")
    tenantId = $account.tenantId
    subscriptions = $subscriptionIds
    locations = $locationIds
    uptimeLookbackDays = $UptimeLookbackDays
    allocationLookbackDays = $AllocationLookbackDays
    sections = $script:SectionStatus
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $outputRoot "manifest.json") -Encoding utf8

$zipPath = "$outputRoot.zip"
if (-not $NoZip) {
    Write-Section "Creating transfer package"
    Compress-Archive -Path (Join-Path $outputRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "Package created: $zipPath" -ForegroundColor Green
}
else {
    Write-Host "Data collected: $outputRoot" -ForegroundColor Green
}

Write-Host "Review manifest.json for skipped or failed optional sections before transferring the package."