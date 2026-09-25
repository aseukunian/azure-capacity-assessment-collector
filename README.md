# Azure Capacity Assessment Collector

This repository contains a read-only PowerShell collector used to gather the Azure inventory and operational data needed for an offline capacity assessment.

The collector creates JSON snapshots and a ZIP file in your environment. It does not deploy, update, stop, start, or delete Azure resources, and it does not upload data anywhere. You review the generated files and choose how to transfer them.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7
- [Azure CLI](https://aka.ms/installazurecliwindows)
- Azure Resource Graph extension
- Access to the Azure tenant and subscriptions being assessed

Install the Resource Graph extension once if needed:

```powershell
az extension add --name resource-graph
```

Sign in to the correct tenant:

```powershell
az login --tenant "<tenant-id>"
```

At startup, the collector runs a preflight before creating the output directory. It checks the PowerShell and Azure CLI versions, the Resource Graph extension, the active Azure CLI session, access to every selected subscription, and a minimal Resource Graph query against the first subscription. Each successful check is printed with `[OK]`; a failed check stops collection with a corrective error message.

## Recommended command

Run the collector from the directory containing `collect_azure_data.ps1`. Explicit subscription and location scopes are recommended:

```powershell
.\collect_azure_data.ps1 `
    -Subscriptions "<subscription-id-1>","<subscription-id-2>" `
    -Locations "westeurope","northeurope"
```

If no subscriptions are provided, the collector uses every enabled subscription visible to the signed-in identity. If no locations are provided, it collects all locations represented by the discovered VMs.

The default output names resemble:

```text
capacity-reservation-data-20260917-143000/
capacity-reservation-data-20260917-143000.zip
```

## Forecast inputs

Azure inventory describes current deployment, but planned growth and placement
flexibility require customer input. Complete
[capacity_forecast_template.xlsx](capacity_forecast_template.xlsx) using the
[forecast input guide](FORECAST_INPUTS.md), then return the workbook alongside
the generated ZIP through the same approved secure channel.

The collector does not currently read or include this workbook automatically.
Do not upload a completed customer workbook to a GitHub issue or commit it to
this repository.

## Parameters

| Parameter | Purpose |
|---|---|
| `-Subscriptions` | One or more Azure subscription IDs; defaults to all accessible enabled subscriptions |
| `-Locations` | ARM location names such as `eastus` or `westeurope`; defaults to all discovered VM locations |
| `-UptimeLookbackDays` | Runtime and cost window; default 30 days, maximum 365 |
| `-AllocationLookbackDays` | Activity Log window; default 30 days, maximum 89 |
| `-AllocationConcurrency` | Concurrent subscription workers for Activity Logs; default 4, range 1–16 |
| `-OutputDirectory` | Custom output directory; it must not already exist |
| `-SkipCost` | Skip Cost Management runtime and cost collection |
| `-SkipAllocationEvents` | Skip per-VM Activity Log collection |
| `-SkipAsr` | Skip Azure Site Recovery collection |
| `-SkipVmSizeInfo` | Skip VM SKU and Capacity Reservation capability collection |
| `-SkipPhysicalZones` | Skip logical-to-physical availability-zone mappings |
| `-NoZip` | Keep only the output directory and do not create a transfer ZIP |

Allocation events are collected concurrently across subscriptions, with four workers by default. VMs within each subscription remain sequential to reduce throttling pressure. Use `-AllocationConcurrency 1` for fully sequential collection, lower the value when throttling is sustained, or use `-SkipAllocationEvents` when that information is not required. Environments whose VMs are concentrated in one subscription will see less benefit from concurrency.

Resource Graph inventory collection reports each subscription batch and result page as it runs. VM and Capacity Reservation queries use batches of 10 subscriptions so large tenant scopes provide regular progress feedback.

## Azure permissions

The collector only performs read operations. The signed-in identity must be able to read:

- Virtual machines, resource groups, subscriptions, and Capacity Reservations through Azure Resource Graph
- Azure Site Recovery protected items unless `-SkipAsr` is used
- Subscription location metadata and Microsoft.Compute VM SKUs
- Regional Microsoft.Compute usage and quota data
- Subscription Activity Logs unless `-SkipAllocationEvents` is used
- Cost Management query data unless `-SkipCost` is used

The Azure `Reader` role normally covers inventory, SKU, location, quota, and Activity Log reads. Cost data commonly also requires `Cost Management Reader` or an equivalent custom role at the relevant scope.

Optional sections that cannot be read are recorded as failed in `manifest.json`; the collector continues where possible. VM inventory is required.

## Collected files

| File | Contents |
|---|---|
| `manifest.json` | Collector version, schema version, selected scope, lookback periods, and status of each section |
| `vms.json` | VM inventory, tags, subscription information, resource groups, sizes, zones, and Capacity Reservation associations |
| `capacity_reservations.json` | Capacity Reservation groups and reservations |
| `asr.json` | Azure Site Recovery status and planned failover targets |
| `physical_zones.json` | Subscription-specific logical-to-physical availability-zone mappings |
| `vm_size_info.json` | VM family, vCPU count, and Capacity Reservation support |
| `compute_quota_usage.json` | Regional Microsoft.Compute usage and quota limits |
| `allocation_events.json` | Summarized VM allocation-related Activity Log events |
| `uptime_daily.json` | Daily billed VM runtime from Cost Management |
| `uptime_cost.json` | Amortized VM cost for the selected window |

The generated package can contain customer-sensitive information, including Azure resource IDs, subscription and resource-group names, resource tags, VM names and sizes, ASR configuration, Activity Log callers and failure messages, and summarized cost records. It does not contain Azure access tokens or credentials.

## Review and transfer

1. Open `manifest.json` and confirm the tenant, subscriptions, locations, collection windows, and section statuses.
2. Review the generated JSON files according to your organization's data-handling requirements.
3. Transfer `capacity-reservation-data-*.zip` only through an approved secure channel.
4. Do not attach generated customer data to a public GitHub issue.

The ZIP is not sent automatically. It remains on the computer where the collector was run until you choose to transfer or delete it.

## Cost access unavailable

Run the collector without Cost Management queries:

```powershell
.\collect_azure_data.ps1 `
    -Subscriptions "<subscription-id>" `
    -Locations "eastus" `
    -SkipCost
```

Your assessment contact may request a separate EA or MCA **Cost and usage (amortized)** Usage Details export through the approved secure transfer channel.

## Troubleshooting

- `Azure CLI was not found`: install Azure CLI and open a new PowerShell session.
- `No active Azure CLI session`: run `az login --tenant "<tenant-id>"`.
- `az graph` is unavailable: run `az extension add --name resource-graph`.
- Preflight reports an inaccessible, disabled, or wrong-tenant subscription: verify the subscription IDs and sign in to the tenant being assessed.
- Resource Graph preflight does not complete: stop with `Ctrl+C`, then test Azure CLI connectivity against one subscription before retrying the collector.
- `No VMs were returned`: confirm the subscription IDs, location filters, and Resource Graph permissions.
- A Resource Graph progress line that does not advance for an extended period can indicate an Azure CLI, authentication, network, or service issue. Stop with `Ctrl+C` and test `az graph query` against one subscription.
- Sustained Activity Log throttling: rerun with a lower value such as `-AllocationConcurrency 2` or `-AllocationConcurrency 1`.
- Optional section failures: review the `sections` object in `manifest.json` and confirm the corresponding permissions.

## Support and security

See [SECURITY.md](SECURITY.md) before reporting a security concern. Never include generated snapshots, credentials, tenant details, or other customer-sensitive data in a public issue.
