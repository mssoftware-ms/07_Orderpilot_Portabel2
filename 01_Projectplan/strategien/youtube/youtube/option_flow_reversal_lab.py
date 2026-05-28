#!/usr/bin/env python3
"""Prototype lab for the option-flow reversal/breakout strategy.

The YouTube transcript describes proprietary option-flow levels. This lab can
consume those levels from CSV when available, and otherwise falls back to a
transparent OHLCV proxy so the execution, risk, and validation mechanics are
testable.
"""

from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from statistics import mean, pstdev
from typing import Iterable, Literal


Bias = Literal["long", "short", "both"]


@dataclass(frozen=True)
class Candle:
    timestamp: int
    open: float
    high: float
    low: float
    close: float
    volume: float


@dataclass(frozen=True)
class Level:
    timestamp: int
    price: float
    direction: str
    source: str


@dataclass(frozen=True)
class Trade:
    entry_time: int
    exit_time: int
    side: str
    entry: float
    stop: float
    target: float
    exit_price: float
    r_multiple: float
    fee_r: float
    reason: str


def load_candles(path: Path) -> list[Candle]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    return [
        Candle(
            timestamp=int(item["timestamp"]),
            open=float(item["open"]),
            high=float(item["high"]),
            low=float(item["low"]),
            close=float(item["close"]),
            volume=float(item["volume"]),
        )
        for item in raw
    ]


def load_levels(path: Path) -> list[Level]:
    levels: list[Level] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            levels.append(
                Level(
                    timestamp=int(row["timestamp"]),
                    price=float(row["price"]),
                    direction=row.get("direction", "both").lower(),
                    source=row.get("source", "external_options_flow"),
                )
            )
    return levels


def day_key(timestamp: int) -> str:
    return datetime.fromtimestamp(timestamp / 1000, tz=timezone.utc).strftime("%Y-%m-%d")


def weekday(timestamp: int) -> int:
    return datetime.fromtimestamp(timestamp / 1000, tz=timezone.utc).weekday()


def is_ny_session_proxy(timestamp: int) -> bool:
    hour = datetime.fromtimestamp(timestamp / 1000, tz=timezone.utc).hour
    minute = datetime.fromtimestamp(timestamp / 1000, tz=timezone.utc).minute
    minutes = hour * 60 + minute
    return (14 * 60 + 30) <= minutes <= (21 * 60)


def atr(candles: list[Candle], index: int, period: int) -> float | None:
    if index < period:
        return None
    true_ranges: list[float] = []
    for i in range(index - period + 1, index + 1):
        prev_close = candles[i - 1].close
        item = candles[i]
        true_ranges.append(
            max(
                item.high - item.low,
                abs(item.high - prev_close),
                abs(item.low - prev_close),
            )
        )
    return mean(true_ranges)


def volume_zscore(candles: list[Candle], index: int, period: int) -> float:
    if index < period:
        return 0.0
    values = [item.volume for item in candles[index - period : index]]
    sigma = pstdev(values)
    if sigma == 0:
        return 0.0
    return (candles[index].volume - mean(values)) / sigma


def build_atr_values(candles: list[Candle], period: int) -> list[float | None]:
    return [atr(candles, index, period) for index in range(len(candles))]


def build_volume_zscore_values(candles: list[Candle], period: int) -> list[float]:
    return [volume_zscore(candles, index, period) for index in range(len(candles))]


def ema(values: list[float], period: int) -> list[float]:
    if not values:
        return []
    alpha = 2.0 / (period + 1.0)
    result = [values[0]]
    for value in values[1:]:
        result.append((value * alpha) + (result[-1] * (1.0 - alpha)))
    return result


def resample_to_4h(candles: list[Candle]) -> list[Candle]:
    bucket_ms = 4 * 60 * 60 * 1000
    buckets: dict[int, list[Candle]] = {}
    for candle in candles:
        buckets.setdefault(candle.timestamp // bucket_ms, []).append(candle)

    result: list[Candle] = []
    for bucket in sorted(buckets):
        items = buckets[bucket]
        result.append(
            Candle(
                timestamp=items[0].timestamp,
                open=items[0].open,
                high=max(item.high for item in items),
                low=min(item.low for item in items),
                close=items[-1].close,
                volume=sum(item.volume for item in items),
            )
        )
    return result


def build_4h_bias(candles: list[Candle]) -> dict[str, Bias]:
    """Approximate the video's 4h wave bias with completed 4h candle data."""
    four_hour = resample_to_4h(candles)
    closes = [item.close for item in four_hour]
    ema_20 = ema(closes, 20)
    by_day: dict[str, Bias] = {}
    for index, candle in enumerate(four_hour):
        if index < 21:
            by_day[day_key(candle.timestamp)] = "both"
            continue
        slope = ema_20[index] - ema_20[index - 3]
        if candle.close > ema_20[index] and slope > 0:
            by_day[day_key(candle.timestamp)] = "long"
        elif candle.close < ema_20[index] and slope < 0:
            by_day[day_key(candle.timestamp)] = "short"
        else:
            by_day[day_key(candle.timestamp)] = "both"
    return by_day


def build_proxy_levels(candles: list[Candle]) -> list[Level]:
    """Create deterministic stand-in levels from prior-day extremes and pivots."""
    by_day: dict[str, list[Candle]] = {}
    for candle in candles:
        by_day.setdefault(day_key(candle.timestamp), []).append(candle)

    levels: list[Level] = []
    ordered_days = sorted(by_day)
    for previous_day, current_day in zip(ordered_days, ordered_days[1:]):
        previous = by_day[previous_day]
        current = by_day[current_day]
        high = max(item.high for item in previous)
        low = min(item.low for item in previous)
        close = previous[-1].close
        pivot = (high + low + close) / 3.0
        range_size = high - low
        candidates = [
            (high, "short", "proxy_prior_day_high"),
            (low, "long", "proxy_prior_day_low"),
            (pivot + range_size * 0.382, "short", "proxy_pivot_r382"),
            (pivot - range_size * 0.382, "long", "proxy_pivot_s382"),
        ]
        start_ts = current[0].timestamp
        for price, direction, source in candidates:
            levels.append(Level(start_ts, price, direction, source))
    return levels


def levels_for_day(levels: Iterable[Level], timestamp: int) -> list[Level]:
    current_day = day_key(timestamp)
    return [level for level in levels if day_key(level.timestamp) == current_day]


def index_levels_by_day(levels: Iterable[Level]) -> dict[str, list[Level]]:
    indexed: dict[str, list[Level]] = {}
    for level in levels:
        indexed.setdefault(day_key(level.timestamp), []).append(level)
    return indexed


def is_rejection(candle: Candle, side: str, level: float) -> bool:
    body_top = max(candle.open, candle.close)
    body_bottom = min(candle.open, candle.close)
    candle_range = max(candle.high - candle.low, 1e-9)
    upper_wick = candle.high - body_top
    lower_wick = body_bottom - candle.low
    if side == "long":
        return candle.low <= level <= candle.high and candle.close > level and lower_wick / candle_range >= 0.35
    return candle.low <= level <= candle.high and candle.close < level and upper_wick / candle_range >= 0.35


def run_backtest(
    candles: list[Candle],
    levels: list[Level],
    *,
    risk_reward: float,
    atr_period: int,
    touch_atr: float,
    stop_atr: float,
    min_volume_z: float,
    skip_friday: bool,
    use_4h_bias: bool,
    taker_fee: float,
    bias_by_day_override: dict[str, Bias] | None = None,
    atr_values: list[float | None] | None = None,
    volume_z_values: list[float] | None = None,
) -> list[Trade]:
    trades: list[Trade] = []
    open_trade: Trade | None = None
    daily_risk_used: dict[str, float] = {}
    bias_by_day = bias_by_day_override if bias_by_day_override is not None else build_4h_bias(candles)
    if not use_4h_bias:
        bias_by_day = {}
    levels_by_day = index_levels_by_day(levels)
    atr_by_index = atr_values if atr_values is not None else build_atr_values(candles, atr_period)
    volume_z_by_index = (
        volume_z_values if volume_z_values is not None else build_volume_zscore_values(candles, 48)
    )

    for index, candle in enumerate(candles):
        if index < atr_period + 1:
            continue

        if open_trade is not None:
            if open_trade.side == "long":
                stop_hit = candle.low <= open_trade.stop
                target_hit = candle.high >= open_trade.target
            else:
                stop_hit = candle.high >= open_trade.stop
                target_hit = candle.low <= open_trade.target

            if stop_hit or target_hit:
                exit_price = open_trade.target if target_hit else open_trade.stop
                r_multiple = risk_reward if target_hit else -1.0
                stop_distance = abs(open_trade.entry - open_trade.stop)
                fee_r = taker_fee * (open_trade.entry + exit_price) / stop_distance
                trades.append(
                    Trade(
                        entry_time=open_trade.entry_time,
                        exit_time=candle.timestamp,
                        side=open_trade.side,
                        entry=open_trade.entry,
                        stop=open_trade.stop,
                        target=open_trade.target,
                        exit_price=exit_price,
                        r_multiple=r_multiple,
                        fee_r=fee_r,
                        reason="target" if target_hit else "stop",
                    )
                )
                open_trade = None
            continue

        if skip_friday and weekday(candle.timestamp) == 4:
            continue
        if not is_ny_session_proxy(candle.timestamp):
            continue
        current_atr = atr_by_index[index]
        if current_atr is None:
            continue
        if volume_z_by_index[index] < min_volume_z:
            continue
        if daily_risk_used.get(day_key(candle.timestamp), 0.0) >= 0.009:
            continue

        for level in levels_by_day.get(day_key(candle.timestamp), []):
            if abs(candle.close - level.price) > current_atr * touch_atr and not (
                candle.low <= level.price <= candle.high
            ):
                continue
            if level.direction not in {"long", "short"}:
                continue
            day_bias = bias_by_day.get(day_key(candle.timestamp), "both")
            if day_bias != "both" and level.direction != day_bias:
                continue
            if not is_rejection(candle, level.direction, level.price):
                continue

            side = level.direction
            entry = candle.close
            stop_distance = max(current_atr * stop_atr, abs(entry - level.price) * 1.2)
            if side == "long":
                stop = entry - stop_distance
                target = entry + stop_distance * risk_reward
            else:
                stop = entry + stop_distance
                target = entry - stop_distance * risk_reward
            open_trade = Trade(candle.timestamp, candle.timestamp, side, entry, stop, target, entry, 0.0, 0.0, "open")
            daily_risk_used[day_key(candle.timestamp)] = daily_risk_used.get(day_key(candle.timestamp), 0.0) + 0.003
            break

    return trades


def summarize(trades: list[Trade]) -> dict[str, float | int]:
    wins = [trade for trade in trades if trade.r_multiple > 0]
    losses = [trade for trade in trades if trade.r_multiple < 0]
    gross_win = sum(trade.r_multiple for trade in wins)
    gross_loss = abs(sum(trade.r_multiple for trade in losses))
    total_r = sum(trade.r_multiple for trade in trades)
    net_r_values = [trade.r_multiple - trade.fee_r for trade in trades]
    net_wins = [value for value in net_r_values if value > 0]
    net_losses = [value for value in net_r_values if value < 0]
    net_gross_win = sum(net_wins)
    net_gross_loss = abs(sum(net_losses))
    net_total_r = sum(net_r_values)
    equity_pct = 0.0
    peak_pct = 0.0
    max_drawdown_pct = 0.0
    target_fee_multiples: list[float] = []
    for trade, net_r in zip(trades, net_r_values):
        equity_pct += net_r * 0.3
        peak_pct = max(peak_pct, equity_pct)
        max_drawdown_pct = max(max_drawdown_pct, peak_pct - equity_pct)
        target_pct = abs(trade.target - trade.entry) / trade.entry
        round_trip_fee = trade.fee_r * abs(trade.entry - trade.stop) / trade.entry
        if round_trip_fee > 0:
            target_fee_multiples.append(target_pct / round_trip_fee)
    return {
        "trades": len(trades),
        "win_rate_pct": round(len(wins) / len(trades) * 100, 2) if trades else 0.0,
        "profit_factor": round(gross_win / gross_loss, 2) if gross_loss else 0.0,
        "total_r": round(total_r, 2),
        "avg_r": round(total_r / len(trades), 3) if trades else 0.0,
        "avg_win_r": round(mean([trade.r_multiple for trade in wins]), 3) if wins else 0.0,
        "net_win_rate_pct": round(len(net_wins) / len(trades) * 100, 2) if trades else 0.0,
        "net_profit_factor": round(net_gross_win / net_gross_loss, 2) if net_gross_loss else 0.0,
        "net_total_r": round(net_total_r, 2),
        "net_avg_r": round(net_total_r / len(trades), 3) if trades else 0.0,
        "fee_r": round(sum(trade.fee_r for trade in trades), 2),
        "max_drawdown_pct": round(max_drawdown_pct, 2),
        "avg_target_fee_multiple": round(mean(target_fee_multiples), 2) if target_fee_multiples else 0.0,
        "wins": len(wins),
        "losses": len(losses),
    }


def evaluate_acceptance_gates(summary: dict[str, float | int]) -> dict[str, object]:
    trades = int(summary["trades"])
    avg_win_r = float(summary["avg_win_r"])
    win_rate_pct = float(summary["win_rate_pct"])
    winrate_threshold = 55.0 if avg_win_r >= 2.5 else 60.0
    gates = {
        "trades": {"passed": trades >= 200, "actual": trades, "minimum": 200},
        "net_profit_factor": {
            "passed": float(summary["net_profit_factor"]) >= 1.5,
            "actual": summary["net_profit_factor"],
            "minimum": 1.5,
        },
        "win_rate": {
            "passed": win_rate_pct >= winrate_threshold,
            "actual": summary["win_rate_pct"],
            "minimum": winrate_threshold,
        },
        "max_drawdown_pct": {
            "passed": float(summary["max_drawdown_pct"]) < 15.0,
            "actual": summary["max_drawdown_pct"],
            "maximum": 15.0,
        },
        "fee_to_target": {
            "passed": float(summary["avg_target_fee_multiple"]) > 3.0,
            "actual": summary["avg_target_fee_multiple"],
            "minimum": 3.0,
        },
        "out_of_sample_profit_factor": {
            "passed": False,
            "actual": "not_evaluated_in_single_run",
            "minimum": ">= 50% of in-sample PF",
        },
    }
    return {"passed": all(bool(item["passed"]) for item in gates.values()), "gates": gates}


def write_trades(path: Path, trades: list[Trade]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "entry_time",
        "exit_time",
        "side",
        "entry",
        "stop",
        "target",
        "exit_price",
        "r_multiple",
        "fee_r",
        "net_r",
        "reason",
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for trade in trades:
            writer.writerow(
                {
                    "entry_time": trade.entry_time,
                    "exit_time": trade.exit_time,
                    "side": trade.side,
                    "entry": round(trade.entry, 2),
                    "stop": round(trade.stop, 2),
                    "target": round(trade.target, 2),
                    "exit_price": round(trade.exit_price, 2),
                    "r_multiple": round(trade.r_multiple, 3),
                    "fee_r": round(trade.fee_r, 3),
                    "net_r": round(trade.r_multiple - trade.fee_r, 3),
                    "reason": trade.reason,
                }
            )


def split_candles(candles: list[Candle], train_ratio: float) -> tuple[list[Candle], list[Candle]]:
    split_index = int(len(candles) * train_ratio)
    return candles[:split_index], candles[split_index:]


def run_parameter_sweep(
    candles: list[Candle],
    *,
    levels_path: Path | None,
    include_friday: bool,
    use_4h_bias: bool,
    taker_fee: float,
) -> list[dict[str, float | int | bool]]:
    train, validation = split_candles(candles, 0.7)
    train_levels = load_levels(levels_path) if levels_path else build_proxy_levels(train)
    validation_levels = load_levels(levels_path) if levels_path else build_proxy_levels(validation)
    train_bias = build_4h_bias(train)
    validation_bias = build_4h_bias(validation)
    train_atr = build_atr_values(train, 14)
    validation_atr = build_atr_values(validation, 14)
    train_volume_z = build_volume_zscore_values(train, 48)
    validation_volume_z = build_volume_zscore_values(validation, 48)
    candidates: list[dict[str, float | int | bool]] = []
    for risk_reward in [2.5, 3.0, 4.0, 5.0]:
        for stop_atr in [0.3, 0.45, 0.6, 0.8]:
            for touch_atr in [0.1, 0.18, 0.3]:
                for min_volume_z in [0.0, 0.75, 1.25, 1.75]:
                    train_summary = summarize(
                        run_backtest(
                            train,
                            train_levels,
                            risk_reward=risk_reward,
                            atr_period=14,
                            touch_atr=touch_atr,
                            stop_atr=stop_atr,
                            min_volume_z=min_volume_z,
                            skip_friday=not include_friday,
                            use_4h_bias=use_4h_bias,
                            taker_fee=taker_fee,
                            bias_by_day_override=train_bias,
                            atr_values=train_atr,
                            volume_z_values=train_volume_z,
                        )
                    )
                    validation_summary = summarize(
                        run_backtest(
                            validation,
                            validation_levels,
                            risk_reward=risk_reward,
                            atr_period=14,
                            touch_atr=touch_atr,
                            stop_atr=stop_atr,
                            min_volume_z=min_volume_z,
                            skip_friday=not include_friday,
                            use_4h_bias=use_4h_bias,
                            taker_fee=taker_fee,
                            bias_by_day_override=validation_bias,
                            atr_values=validation_atr,
                            volume_z_values=validation_volume_z,
                        )
                    )
                    candidates.append(
                        {
                            "risk_reward": risk_reward,
                            "stop_atr": stop_atr,
                            "touch_atr": touch_atr,
                            "min_volume_z": min_volume_z,
                            "use_4h_bias": use_4h_bias,
                            "train_trades": train_summary["trades"],
                            "train_net_pf": train_summary["net_profit_factor"],
                            "train_net_r": train_summary["net_total_r"],
                            "validation_trades": validation_summary["trades"],
                            "validation_net_pf": validation_summary["net_profit_factor"],
                            "validation_net_r": validation_summary["net_total_r"],
                            "validation_net_wr": validation_summary["net_win_rate_pct"],
                        }
                    )
    return sorted(
        candidates,
        key=lambda item: (
            float(item["validation_net_r"]),
            float(item["validation_net_pf"]),
            int(item["validation_trades"]),
        ),
        reverse=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candles", type=Path, required=True)
    parser.add_argument("--levels", type=Path)
    parser.add_argument("--risk-reward", type=float, default=4.0)
    parser.add_argument("--atr-period", type=int, default=14)
    parser.add_argument("--touch-atr", type=float, default=0.18)
    parser.add_argument("--stop-atr", type=float, default=0.45)
    parser.add_argument("--min-volume-z", type=float, default=1.25)
    parser.add_argument("--include-friday", action="store_true")
    parser.add_argument("--disable-4h-bias", action="store_true")
    parser.add_argument("--taker-fee", type=float, default=0.0006)
    parser.add_argument("--trades-output", type=Path)
    parser.add_argument("--evaluate-gates", action="store_true")
    parser.add_argument("--sweep", action="store_true")
    args = parser.parse_args()

    candles = load_candles(args.candles)
    if args.sweep:
        sweep = run_parameter_sweep(
            candles,
            levels_path=args.levels,
            include_friday=args.include_friday,
            use_4h_bias=not args.disable_4h_bias,
            taker_fee=args.taker_fee,
        )
        print(json.dumps(sweep[:10], indent=2, sort_keys=True))
        return

    levels = load_levels(args.levels) if args.levels else build_proxy_levels(candles)
    trades = run_backtest(
        candles,
        levels,
        risk_reward=args.risk_reward,
        atr_period=args.atr_period,
        touch_atr=args.touch_atr,
        stop_atr=args.stop_atr,
        min_volume_z=args.min_volume_z,
        skip_friday=not args.include_friday,
        use_4h_bias=not args.disable_4h_bias,
        taker_fee=args.taker_fee,
    )
    result = summarize(trades)
    result["level_source"] = "external_csv" if args.levels else "ohlcv_proxy"
    result["risk_per_trade_pct"] = 0.3
    result["max_daily_risk_pct"] = 0.9
    result["use_4h_bias"] = not args.disable_4h_bias
    result["taker_fee_per_side"] = args.taker_fee
    if args.trades_output:
        write_trades(args.trades_output, trades)
        result["trades_output"] = str(args.trades_output)
    if args.evaluate_gates:
        result["acceptance_gates"] = evaluate_acceptance_gates(result)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
