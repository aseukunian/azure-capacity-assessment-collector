# Changelog

All notable changes to the Azure Capacity Assessment Collector are documented here.

## [1.0.2] - 2026-09-25

### Added

- Added startup checks for PowerShell, Azure CLI, the Resource Graph extension, authentication, selected subscription access, active-tenant consistency, and Resource Graph connectivity.

## [1.0.1] - 2026-09-25

### Changed

- Added subscription-batch and page-level progress feedback for Azure Resource Graph collection.
- Batched VM and Capacity Reservation inventory queries to improve feedback for large subscription scopes.

## [1.0.0] - 2026-09-17

### Added

- Read-only collection of VM and Capacity Reservation inventory.
- Optional collection of Azure Site Recovery targets, physical-zone mappings, VM SKU capabilities, compute quotas, Cost Management runtime and cost, and VM allocation events.
- Versioned snapshot manifest and ZIP packaging for reviewed transfer.
