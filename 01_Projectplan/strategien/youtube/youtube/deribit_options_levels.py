#!/usr/bin/env python3
"""Export current Deribit BTC option-interest levels for the reversal lab."""

from __future__ import annotations

import argparse
import csv
import json
import re
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


INSTRUMENT_RE = re.compile(r"^(?P<currency>[A-Z]+)-(?P<expiry>[0-9A-Z]+)-(?P<strike>[0-9]+)-(?P<kind>[CP])$")


@dataclass(frozen=True)
class OptionSummary:
    instrument_name: str
    strike: float
    kind: str
    open_interest: float
    volume: float


def fetch_book_summary(currency: str) -> list[dict[str, object]]:
    query = urllib.parse.urlencode({"currency": currency.upper(), "kind": "option"})
    url = f"https://www.deribit.com/api/v2/public/get_book_summary_by_currency?{query}"
    with urllib.request.urlopen(url, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    result = payload.get("result")
    if not isinstance(result, list):
        raise RuntimeError(f"Unexpected Deribit response: {payload}")
    return result


def parse_summary(item: dict[str, object]) -> OptionSummary | None:
    instrument_name = str(item.get("instrument_name", ""))
    match = INSTRUMENT_RE.match(instrument_name)
    if match is None:
        return None
    return OptionSummary(
        instrument_name=instrument_name,
        strike=float(match.group("strike")),
        kind=match.group("kind"),
        open_interest=float(item.get("open_interest") or 0.0),
        volume=float(item.get("volume") or 0.0),
    )


def aggregate_by_strike(options: list[OptionSummary], kind: str, field: str) -> list[tuple[float, float]]:
    totals: dict[float, float] = {}
    for option in options:
        if option.kind != kind:
            continue
        value = option.open_interest if field == "open_interest" else option.volume
        totals[option.strike] = totals.get(option.strike, 0.0) + value
    return sorted(totals.items(), key=lambda item: item[1], reverse=True)


def write_levels(path: Path, rows: list[dict[str, object]], *, append: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    file_exists = path.exists() and path.stat().st_size > 0
    mode = "a" if append else "w"
    with path.open(mode, encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["timestamp", "price", "direction", "source"])
        if not append or not file_exists:
            writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--currency", default="BTC")
    parser.add_argument("--top-n", type=int, default=5)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("01_Projectplan/strategien/youtube/youtube/deribit_btc_options_levels.csv"),
    )
    parser.add_argument(
        "--append",
        action="store_true",
        help="Append this snapshot to an archive CSV instead of replacing the file.",
    )
    args = parser.parse_args()

    summaries = [parse_summary(item) for item in fetch_book_summary(args.currency)]
    options = [item for item in summaries if item is not None]
    timestamp = int(datetime.now(tz=timezone.utc).timestamp() * 1000)

    rows: list[dict[str, object]] = []
    for strike, _value in aggregate_by_strike(options, "C", "open_interest")[: args.top_n]:
        rows.append({"timestamp": timestamp, "price": strike, "direction": "short", "source": "deribit_call_oi_wall"})
    for strike, _value in aggregate_by_strike(options, "P", "open_interest")[: args.top_n]:
        rows.append({"timestamp": timestamp, "price": strike, "direction": "long", "source": "deribit_put_oi_wall"})
    for strike, _value in aggregate_by_strike(options, "C", "volume")[: args.top_n]:
        rows.append({"timestamp": timestamp, "price": strike, "direction": "short", "source": "deribit_call_volume_wall"})
    for strike, _value in aggregate_by_strike(options, "P", "volume")[: args.top_n]:
        rows.append({"timestamp": timestamp, "price": strike, "direction": "long", "source": "deribit_put_volume_wall"})

    write_levels(args.output, rows, append=args.append)
    print(json.dumps({"output": str(args.output), "levels": len(rows), "append": args.append}, indent=2))


if __name__ == "__main__":
    main()
