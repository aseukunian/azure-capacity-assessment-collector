# Capacity Forecast Inputs

Azure inventory provides the current deployment baseline. It cannot identify
planned migrations, launches, seasonal events, disaster-recovery exercises, or
business growth. Use `capacity_forecast_template.xlsx` to provide those demand
assumptions for the capacity assessment.

The completed workbook can contain customer-sensitive planning information.
Do not upload it to GitHub. Return it alongside the collector ZIP through the
approved secure transfer channel agreed with the assessment contact.

## Workflow

1. Download and open `capacity_forecast_template.xlsx`.
2. Read the `Instructions` worksheet.
3. Add one row per workload, forecast date, and scenario.
4. Complete the `Compute Workloads` worksheet for VM-based demand.
5. Complete the `PaaS Workloads` worksheet for applicable platform services.
6. Use Azure ARM region names such as `westeurope` and `northeurope`.
7. Return the completed workbook alongside `capacity-reservation-data-*.zip`.

At least the `Expected` scenario is required. Add `Low` and `High` scenarios
where the range is material. Use explicit forecast quantities as the source of
truth; growth percentages are supporting context.

## Compute workloads

Provide the following for each VM workload:

- Target region and subscription ID
- VM SKU and family
- Current VM and vCore quantities
- Forecast VM and vCore quantities with required dates
- Availability-zone requirements
- Existing or required On-demand Capacity Reservation (ODCR)
- Region and SKU flexibility, including approved alternatives

Use multiple rows when demand changes on different dates. For example, a
workload requiring 20 VMs in January and 30 in June should have two rows.

### Constraint values

Use these controlled values where possible:

| Field | Values |
|---|---|
| `Scenario` | `Low`, `Expected`, `High` |
| `Reservation Requirement` | `None`, `Existing ODCR`, `New ODCR` |
| `Region Flexibility` | `Fixed`, `Approved list`, `Paired region`, `Flexible` |
| `SKU Flexibility` | `Exact`, `Same family`, `Approved alternatives`, `Flexible` |
| `Confidence` | `Low`, `Medium`, `High` |

For `Approved list` or `Approved alternatives`, enter the permitted regions or
SKUs in the corresponding alternatives field.

## PaaS workloads

PaaS capacity must be expressed in the service's native unit. Add one row per
service, forecast date, and scenario.

| Service example | Capacity unit example |
|---|---|
| Azure SQL Database or Managed Instance | `vCores` or `DTUs` |
| Azure Cosmos DB | `RU/s` |
| Azure Kubernetes Service | `nodes` and, where needed, `vCores` |
| Azure App Service | `instances` |
| Azure Event Hubs | `throughput units` or `processing units` |
| Azure Service Bus | `messaging units` |
| Microsoft Fabric | `CUs` |

Record normal forecast capacity and expected peak capacity separately. Specify
whether scaling is manual, scheduled, or automatic, and identify any zonal or
regional placement constraint.

Only include PaaS services agreed as in scope with the assessment team. Each
service has different capacity behavior and requires a service-specific review.

## Data ownership

Current deployment values may be prepopulated or verified from the collector
output. Workload mapping, planned growth, target dates, placement constraints,
and flexibility must be confirmed by the customer workload owner.

Use workload aliases when possible and avoid personal data, credentials,
connection strings, or other secrets in names and notes.