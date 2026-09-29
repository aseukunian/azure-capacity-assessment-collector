[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $InputDirectory,

    [Parameter()]
    [string] $OutputPath,

    [Parameter()]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RequiredProperty {
    param(
        [Parameter()][AllowNull()][object] $InputObject,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Context
    )

    if ($null -eq $InputObject -or $InputObject.PSObject.Properties.Name -notcontains $Name) {
        throw "$Context is missing required property '$Name'."
    }
    return $InputObject.$Name
}

function Get-RequiredString {
    param(
        [Parameter()][AllowNull()][object] $InputObject,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Context
    )

    $value = Get-RequiredProperty -InputObject $InputObject -Name $Name -Context $Context
    $text = [string]$value
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "$Context property '$Name' must be a non-empty string."
    }
    return $text
}

function Assert-RequiredCollection {
    param(
        [Parameter()][AllowNull()][object] $InputObject,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Context
    )

    if ($null -eq $InputObject -or $InputObject.PSObject.Properties.Name -notcontains $Name) {
        throw "$Context is missing required property '$Name'."
    }
    $value = $InputObject.PSObject.Properties[$Name].Value
    if ($null -eq $value) {
        throw "$Context property '$Name' must be an array, not null."
    }
}

function ConvertTo-RequiredInt64 {
    param(
        [Parameter()][AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Context
    )

    $converted = [int64]0
    if ($null -eq $Value -or -not [int64]::TryParse(
        [string]$Value,
        [System.Globalization.NumberStyles]::Integer,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$converted
    )) {
        throw "$Context must be an integer."
    }
    return $converted
}

function Get-PagedValues {
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]] $Pages,
        [Parameter(Mandatory)][string] $Context
    )

    $values = [System.Collections.Generic.List[object]]::new()
    foreach ($page in @($Pages)) {
        Assert-RequiredCollection -InputObject $page -Name "value" -Context $Context
        foreach ($value in @($page.value)) {
            if ($null -eq $value) {
                throw "$Context contains a null record."
            }
            $values.Add($value)
        }
    }
    return $values.ToArray()
}

$inputRoot = [System.IO.Path]::GetFullPath($InputDirectory)
if (-not (Test-Path -LiteralPath $inputRoot -PathType Container)) {
    throw "Input directory does not exist: $inputRoot"
}

$outputFile = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $inputRoot "compute_quota_usage.json"
}
else {
    [System.IO.Path]::GetFullPath($OutputPath)
}
$outputParent = Split-Path -Parent $outputFile
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "Output directory does not exist: $outputParent"
}
if ((Test-Path -LiteralPath $outputFile) -and -not $Force) {
    throw "Output file already exists: $outputFile. Use -Force to replace it."
}

$inputFiles = @(
    Get-ChildItem -LiteralPath $inputRoot -File -Filter "quota-usage-*.json" |
        Sort-Object -Property FullName
)
if ($inputFiles.Count -eq 0) {
    throw "No quota-usage-*.json files were found in: $inputRoot"
}

$snapshotsBySubscription = @{}
$tenantId = $null
foreach ($file in $inputFiles) {
    if ($file.Name -notmatch '^quota-usage-([0-9a-fA-F-]{36})-(.+)\.json$') {
        throw "Input filename does not contain a valid subscription ID: $($file.FullName)"
    }
    $filenameSubscriptionId = $matches[1].ToLowerInvariant()
    $parsedFilenameSubscriptionId = [guid]::Empty
    if (-not [guid]::TryParse($filenameSubscriptionId, [ref]$parsedFilenameSubscriptionId)) {
        throw "Input filename does not contain a valid subscription ID: $($file.FullName)"
    }

    try {
        $parsedJson = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    }
    catch {
        throw "Could not parse JSON file '$($file.FullName)': $($_.Exception.Message)"
    }
    $rootObjects = @($parsedJson)
    if ($rootObjects.Count -ne 1) {
        throw "File '$($file.FullName)' must contain one root object; found $($rootObjects.Count)."
    }
    $root = $rootObjects[0]

    Assert-RequiredCollection -InputObject $root -Name "quotausage" -Context "File '$($file.FullName)'"
    $quotaUsageEntries = @($root.quotausage)
    if ($quotaUsageEntries.Count -ne 1) {
        throw "File '$($file.FullName)' must contain exactly one quotausage entry; found $($quotaUsageEntries.Count)."
    }
    $entry = $quotaUsageEntries[0]
    $entryContext = "File '$($file.FullName)' quotausage entry"
    $entryTenantId = (Get-RequiredString -InputObject $entry -Name "tenantId" -Context $entryContext).ToLowerInvariant()
    $entrySubscriptionId = (Get-RequiredString -InputObject $entry -Name "subscriptionId" -Context $entryContext).ToLowerInvariant()

    $parsedTenantId = [guid]::Empty
    if (-not [guid]::TryParse($entryTenantId, [ref]$parsedTenantId)) {
        throw "$entryContext has invalid tenantId '$entryTenantId'."
    }
    $parsedSubscriptionId = [guid]::Empty
    if (-not [guid]::TryParse($entrySubscriptionId, [ref]$parsedSubscriptionId)) {
        throw "$entryContext has invalid subscriptionId '$entrySubscriptionId'."
    }
    if ($entrySubscriptionId -ne $filenameSubscriptionId) {
        throw "File '$($file.FullName)' subscriptionId '$entrySubscriptionId' does not match filename subscription ID '$filenameSubscriptionId'."
    }
    if ($null -eq $tenantId) {
        $tenantId = $entryTenantId
    }
    elseif ($entryTenantId -ne $tenantId) {
        throw "File '$($file.FullName)' belongs to tenant '$entryTenantId'; expected tenant '$tenantId'."
    }

    $collectedAtText = Get-RequiredString -InputObject $entry -Name "collectedAtUtc" -Context $entryContext
    $collectedAt = [datetimeoffset]::MinValue
    $dateStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
        [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [datetimeoffset]::TryParse(
        $collectedAtText,
        [System.Globalization.CultureInfo]::InvariantCulture,
        $dateStyles,
        [ref]$collectedAt
    )) {
        throw "$entryContext has invalid collectedAtUtc '$collectedAtText'."
    }
    Assert-RequiredCollection -InputObject $entry -Name "regions" -Context $entryContext

    $snapshot = [pscustomobject]@{
        path = $file.FullName
        tenant_id = $entryTenantId
        subscription_id = $entrySubscriptionId
        collected_at = $collectedAt
        entry = $entry
    }
    if (-not $snapshotsBySubscription.ContainsKey($entrySubscriptionId)) {
        $snapshotsBySubscription[$entrySubscriptionId] = $snapshot
    }
    else {
        $current = $snapshotsBySubscription[$entrySubscriptionId]
        if (
            $snapshot.collected_at -gt $current.collected_at -or
            (
                $snapshot.collected_at -eq $current.collected_at -and
                [string]::CompareOrdinal($snapshot.path, $current.path) -gt 0
            )
        ) {
            $snapshotsBySubscription[$entrySubscriptionId] = $snapshot
        }
    }
}

$outputRows = [System.Collections.Generic.List[object]]::new()
foreach ($snapshot in @($snapshotsBySubscription.Values | Sort-Object -Property subscription_id)) {
    $locations = @{}
    Assert-RequiredCollection -InputObject $snapshot.entry -Name "regions" -Context "File '$($snapshot.path)' quotausage entry"
    foreach ($region in @($snapshot.entry.regions)) {
        $regionContext = "File '$($snapshot.path)' region"
        $location = (Get-RequiredString -InputObject $region -Name "location" -Context $regionContext).ToLowerInvariant()
        $regionContext = "File '$($snapshot.path)' region '$location'"
        if ($locations.ContainsKey($location)) {
            throw "File '$($snapshot.path)' contains duplicate region '$location'."
        }
        $locations[$location] = $true
        Assert-RequiredCollection -InputObject $region -Name "usages" -Context $regionContext
        Assert-RequiredCollection -InputObject $region -Name "quotas" -Context $regionContext
        $usagePages = @($region.usages)
        $quotaPages = @($region.quotas)
        $usageItems = @(Get-PagedValues -Pages $usagePages -Context "$regionContext usages page")
        $quotaItems = @(Get-PagedValues -Pages $quotaPages -Context "$regionContext quotas page")

        $usageByName = @{}
        foreach ($usageItem in $usageItems) {
            $usageProperties = Get-RequiredProperty -InputObject $usageItem -Name "properties" -Context "$regionContext usage record"
            $usageName = Get-RequiredProperty -InputObject $usageProperties -Name "name" -Context "$regionContext usage properties"
            $resourceName = Get-RequiredString -InputObject $usageName -Name "value" -Context "$regionContext usage name"
            if ($usageByName.ContainsKey($resourceName)) {
                throw "$regionContext contains duplicate usage name '$resourceName'."
            }
            $localizedName = Get-RequiredString -InputObject $usageName -Name "localizedValue" -Context "$regionContext usage name '$resourceName'"
            $unit = Get-RequiredString -InputObject $usageProperties -Name "unit" -Context "$regionContext usage '$resourceName'"
            $usages = Get-RequiredProperty -InputObject $usageProperties -Name "usages" -Context "$regionContext usage '$resourceName'"
            $currentValue = ConvertTo-RequiredInt64 -Value (
                Get-RequiredProperty -InputObject $usages -Name "value" -Context "$regionContext usage '$resourceName'"
            ) -Context "$regionContext usage '$resourceName' value"
            $usageByName[$resourceName] = [pscustomobject]@{
                resource_name = $resourceName
                localized_name = $localizedName
                current_value = $currentValue
                unit = $unit
            }
        }

        $quotaByName = @{}
        foreach ($quotaItem in $quotaItems) {
            $quotaProperties = Get-RequiredProperty -InputObject $quotaItem -Name "properties" -Context "$regionContext quota record"
            $quotaName = Get-RequiredProperty -InputObject $quotaProperties -Name "name" -Context "$regionContext quota properties"
            $resourceName = Get-RequiredString -InputObject $quotaName -Name "value" -Context "$regionContext quota name"
            if ($quotaByName.ContainsKey($resourceName)) {
                throw "$regionContext contains duplicate quota name '$resourceName'."
            }
            $localizedName = Get-RequiredString -InputObject $quotaName -Name "localizedValue" -Context "$regionContext quota name '$resourceName'"
            $unit = Get-RequiredString -InputObject $quotaProperties -Name "unit" -Context "$regionContext quota '$resourceName'"
            $limit = Get-RequiredProperty -InputObject $quotaProperties -Name "limit" -Context "$regionContext quota '$resourceName'"
            $limitValue = ConvertTo-RequiredInt64 -Value (
                Get-RequiredProperty -InputObject $limit -Name "value" -Context "$regionContext quota '$resourceName' limit"
            ) -Context "$regionContext quota '$resourceName' limit value"
            $quotaByName[$resourceName] = [pscustomobject]@{
                resource_name = $resourceName
                localized_name = $localizedName
                limit = $limitValue
                unit = $unit
            }
        }

        foreach ($resourceName in @($usageByName.Keys | Sort-Object)) {
            if (-not $quotaByName.ContainsKey($resourceName)) {
                throw "$regionContext usage '$resourceName' has no matching quota."
            }
            $usage = $usageByName[$resourceName]
            $quota = $quotaByName[$resourceName]
            if ($usage.localized_name -ne $quota.localized_name) {
                throw "$regionContext '$resourceName' localized names do not match between usage and quota."
            }
            if ($usage.unit -ne $quota.unit) {
                throw "$regionContext '$resourceName' units do not match between usage and quota."
            }
            $outputRows.Add([pscustomobject][ordered]@{
                subscription_id = $snapshot.subscription_id
                location = $location
                resource_name = $usage.resource_name
                localized_name = $usage.localized_name
                current_value = $usage.current_value
                limit = $quota.limit
                unit = $usage.unit
            })
        }
        foreach ($resourceName in $quotaByName.Keys) {
            if (-not $usageByName.ContainsKey($resourceName)) {
                throw "$regionContext quota '$resourceName' has no matching usage."
            }
        }
    }
}

$sortedRows = @(
    $outputRows.ToArray() |
        Sort-Object -Property subscription_id, location, resource_name
)
$temporaryOutput = Join-Path $outputParent ([System.IO.Path]::GetRandomFileName())
try {
    ConvertTo-Json -InputObject $sortedRows -Depth 20 |
        Set-Content -LiteralPath $temporaryOutput -Encoding utf8
    Move-Item -LiteralPath $temporaryOutput -Destination $outputFile -Force:$Force
}
finally {
    if (Test-Path -LiteralPath $temporaryOutput) {
        Remove-Item -LiteralPath $temporaryOutput -Force
    }
}

Write-Host "Merged $($inputFiles.Count) files into $($snapshotsBySubscription.Count) subscription snapshots."
Write-Host "Wrote $($sortedRows.Count) quota records: $outputFile" -ForegroundColor Green
