"""Build an Excel allocation report from an existing collector output folder.

This script is intentionally offline: it reads JSON files produced by
collect_azure_data.ps1 and never contacts Azure.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pandas as pd


EVENT_FILE = "allocation_events.json"
VM_FILE = "vms.json"
OPTIONAL_FILES = {
    "capacity_reservations": "capacity_reservations.json",
    "physical_zones": "physical_zones.json",
    "vm_size_info": "vm_size_info.json",
}


def load_json_array(path: Path, required: bool = True) -> list[dict[str, Any]]:
    if not path.exists():
        if required:
            raise FileNotFoundError(f"Required collector file is missing: {path}")
        return []

    with path.open(encoding="utf-8-sig") as stream:
        value = json.load(stream)
    if isinstance(value, dict):
        value = [value]
    if not isinstance(value, list):
        raise ValueError(f"Expected a JSON array or object in {path}")
    if not all(isinstance(row, dict) for row in value):
        raise ValueError(f"Expected every row in {path} to be a JSON object")
    return value


def load_manifest(input_dir: Path) -> dict[str, Any]:
    path = input_dir / "manifest.json"
    if not path.exists():
        return {}
    with path.open(encoding="utf-8-sig") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object in {path}")
    return value


def normalized(value: Any) -> str:
    return str(value or "").strip().lower()


def normalize_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Deduplicate event summaries while preserving their original fields."""
    seen: set[tuple[tuple[str, str], ...]] = set()
    result: list[dict[str, Any]] = []
    for event in events:
        key = tuple(sorted((str(name), repr(value)) for name, value in event.items()))
        if key not in seen:
            seen.add(key)
            result.append(dict(event))
    return result


def add_allocation_summary(
    vms: list[dict[str, Any]], events: list[dict[str, Any]]
) -> pd.DataFrame:
    """Add per-VM allocation counts and latest failure information."""
    by_vm: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in normalize_events(events):
        if normalized(event.get("operationName")) == (
            "microsoft.compute/virtualmachines/start/action"
        ):
            by_vm[normalized(event.get("id"))].append(event)

    rows: list[dict[str, Any]] = []
    for vm in vms:
        row = dict(vm)
        vm_events = by_vm.get(normalized(vm.get("id")), [])
        successful = [
            event for event in vm_events if normalized(event.get("status")) == "succeeded"
        ]
        failed = [
            event for event in vm_events if normalized(event.get("status")) == "failed"
        ]
        other = [
            event
            for event in vm_events
            if normalized(event.get("status")) not in {"succeeded", "failed"}
        ]
        failed.sort(key=lambda event: str(event.get("eventTimestamp") or ""), reverse=True)
        latest_failed = failed[0] if failed else {}
        total = len(successful) + len(failed) + len(other)

        row.update(
            {
                "successfulAllocations": len(successful),
                "failedAllocations": len(failed),
                "otherAllocations": len(other),
                "successfulAllocationRate": (
                    len(successful) / total if total else None
                ),
                "lastFailedAllocation": latest_failed.get("eventTimestamp"),
                "lastFailedAllocationReason": latest_failed.get("reason"),
                "lastFailedAllocationMessage": latest_failed.get("message"),
            }
        )
        rows.append(row)
    return pd.DataFrame(rows)


def enrich_vm_sizes(vms: pd.DataFrame, size_rows: list[dict[str, Any]]) -> pd.DataFrame:
    if vms.empty or not size_rows:
        return vms
    sizes = pd.DataFrame(size_rows).rename(
        columns={
            "vm_size": "vmSize",
            "vm_family": "vmFamily",
            "vcpu_count": "vcpuCount",
            "capacity_reservation_supported": "capacityReservationSupported",
        }
    )
    keys = ["location", "vmSize"]
    available = [key for key in keys if key in sizes.columns and key in vms.columns]
    if len(available) != len(keys):
        return vms
    sizes = sizes[available + [
        column
        for column in (
            "vmFamily",
            "vcpuCount",
            "capacityReservationSupported",
        )
        if column in sizes.columns
    ]].drop_duplicates(available)
    return vms.merge(sizes, how="left", on=available, validate="many_to_one")


def enrich_physical_zones(
    frame: pd.DataFrame, physical_rows: list[dict[str, Any]]
) -> pd.DataFrame:
    if frame.empty or not physical_rows:
        return frame
    zones = pd.DataFrame(physical_rows)
    required = {"subscription_id", "location", "logical_zone", "physical_zone"}
    if not required.issubset(zones.columns):
        return frame
    left = frame.copy()
    left["_subscription_join"] = left["subscriptionId"].map(normalized)
    left["_location_join"] = left["location"].map(normalized)
    left["_zone_join"] = left["zone"].map(normalized)
    zones = zones.copy()
    zones["_subscription_join"] = zones["subscription_id"].map(normalized)
    zones["_location_join"] = zones["location"].map(normalized)
    zones["_zone_join"] = zones["logical_zone"].map(normalized)
    zones = zones[
        ["_subscription_join", "_location_join", "_zone_join", "physical_zone"]
    ].drop_duplicates()
    left = left.merge(
        zones,
        how="left",
        on=["_subscription_join", "_location_join", "_zone_join"],
        validate="many_to_one",
    )
    left = left.drop(columns=["_subscription_join", "_location_join", "_zone_join"])
    return left.rename(columns={"physical_zone": "physicalZone"})


def build_report(input_dir: Path, output_path: Path) -> dict[str, int]:
    manifest = load_manifest(input_dir)
    vms = load_json_array(input_dir / VM_FILE)
    events = normalize_events(load_json_array(input_dir / EVENT_FILE))
    vm_frame = add_allocation_summary(vms, events)

    optional: dict[str, list[dict[str, Any]]] = {}
    for key, filename in OPTIONAL_FILES.items():
        optional[key] = load_json_array(input_dir / filename, required=False)

    vm_frame = enrich_vm_sizes(vm_frame, optional["vm_size_info"])
    if {"subscriptionId", "location", "zone"}.issubset(vm_frame.columns):
        vm_frame = enrich_physical_zones(vm_frame, optional["physical_zones"])

    event_frame = pd.DataFrame(events)
    if not event_frame.empty:
        event_frame = event_frame.sort_values(
            by=[column for column in ("id", "eventTimestamp") if column in event_frame],
            kind="stable",
        )

    summary = pd.DataFrame(
        [
            {"metric": "collectorVersion", "value": manifest.get("collectorVersion")},
            {"metric": "collectionMode", "value": manifest.get("collectionMode")},
            {"metric": "vmCount", "value": len(vms)},
            {"metric": "eventCount", "value": len(events)},
            {
                "metric": "startEventCount",
                "value": sum(
                    normalized(event.get("operationName"))
                    == "microsoft.compute/virtualmachines/start/action"
                    for event in events
                ),
            },
            {
                "metric": "failedStartEventCount",
                "value": sum(
                    normalized(event.get("operationName"))
                    == "microsoft.compute/virtualmachines/start/action"
                    and normalized(event.get("status")) == "failed"
                    for event in events
                ),
            },
        ]
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with pd.ExcelWriter(output_path, engine="openpyxl") as writer:
        vm_frame.to_excel(writer, index=False, sheet_name="Virtual Machines")
        event_frame.to_excel(writer, index=False, sheet_name="VM Allocation Events")
        summary.to_excel(writer, index=False, sheet_name="Collection Summary")
        if optional["capacity_reservations"]:
            pd.DataFrame(optional["capacity_reservations"]).to_excel(
                writer, index=False, sheet_name="Capacity Reservations"
            )
        if optional["vm_size_info"]:
            pd.DataFrame(optional["vm_size_info"]).to_excel(
                writer, index=False, sheet_name="CR Support"
            )
        if optional["physical_zones"]:
            pd.DataFrame(optional["physical_zones"]).to_excel(
                writer, index=False, sheet_name="Physical Zones"
            )

    return {
        "vms": len(vms),
        "events": len(events),
        "failed_start_events": int(summary.loc[
            summary["metric"] == "failedStartEventCount", "value"
        ].iloc[0]),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create an Excel allocation report from collector JSON output."
    )
    parser.add_argument(
        "input_dir",
        type=Path,
        help="Collector output directory containing vms.json and allocation_events.json",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output .xlsx path; defaults to a timestamped file beside input_dir",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    output = args.output or (
        args.input_dir
        / f"{datetime.now(timezone.utc):%Y-%m-%d_%H-%M-%S}_capacity_reservations_report.xlsx"
    )
    counts = build_report(args.input_dir, output)
    print(
        f"Created {output} "
        f"({counts['vms']} VMs, {counts['events']} events, "
        f"{counts['failed_start_events']} failed start events)."
    )


if __name__ == "__main__":
    main()
