"""Print the medians and the gates of bench runs (phase 3b, Task 4).

Usage: python3 -I tools/bench/summary.py [--hitches FILE]... RESULTS.jsonl...

Each results file is one run of the debug bench: one JSON line (a BenchSample) for each phase,
with the fields phase, seconds, frames, missed, excludedSeconds, appFootprint, childFootprint,
appInstructions and appCPUSeconds. The script prints a table of each phase with the median of
the runs, then the gates:
- drag and resize: at least 118 fps and at most 2.0 missed frames a second;
- footprint: the app and its children under 300 MB (the highest phase of each run).

The frame counter of the app gives the fps (the frames divided by the seconds of the phase less
the excluded seconds) and the missed frames a second (the missed frames divided by the seconds).

--hitches FILE gives the Instruments result of the drag and the resize (pre-flight ruling 11):
{"runs": [{"drag": PHASE, "resize": PHASE}, ...]}, with PHASE = {"seconds": s, "presented": n,
"periodMs": p, "hitchesMs": [h, ...]}. The fps is the presented frames divided by the seconds.
The missed frames a second is the sum of floor(h / p + 0.5) over the hitches (halves round up),
divided by the seconds.
--hitches can come more than one time (run.sh --trace writes one file for each run). The runs of
all the files count. With this file, the drag and resize gates use the Instruments result, and
the script prints the frame counter result as the second result.

Exit 0: each gate passes. Exit 1: a gate fails. Exit 2: the input cannot be read.
"""

import json
import math
import statistics
import sys

MIB = 1048576
MIN_FPS = 118.0
MAX_MISSED = 2.0
MAX_FOOTPRINT_MB = 300.0
FIELDS = (
    "phase", "seconds", "frames", "missed", "excludedSeconds", "appFootprint",
    "childFootprint", "appInstructions", "appCPUSeconds",
)
GATED = ("drag", "resize")
HITCH_FIELDS = ("seconds", "presented", "periodMs", "hitchesMs")


class InputError(Exception):
    pass


def is_number(value):
    """True for an int or a float. A bool is not a number here."""
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def numbers(values, where):
    """Raise InputError when a value is not a number."""
    for name, value in values:
        if not is_number(value):
            raise InputError(f"{where}: {name} is not a number: {json.dumps(value)}")


def read_run(path):
    """Return the samples of one results file by phase, in the order of the file."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = [line for line in handle.read().splitlines() if line.strip()]
    except OSError as error:
        raise InputError(f"cannot read {path}: {error}") from error
    run = {}
    for number, line in enumerate(lines, start=1):
        try:
            sample = json.loads(line)
        except json.JSONDecodeError as error:
            raise InputError(f"{path}:{number}: not JSON: {error}") from error
        if not isinstance(sample, dict) or any(field not in sample for field in FIELDS):
            raise InputError(f"{path}:{number}: a sample needs the fields {', '.join(FIELDS)}")
        if not isinstance(sample["phase"], str):
            raise InputError(f"{path}:{number}: the phase is not a text")
        numbers([(field, sample[field]) for field in FIELDS if field != "phase"],
                f"{path}:{number}")
        if sample["seconds"] <= 0:
            raise InputError(f"{path}:{number}: a phase of no time")
        run[sample["phase"]] = sample
    for phase in GATED:
        if phase not in run:
            raise InputError(f"{path}: no {phase} phase")
    return run


def read_hitches(path):
    """Return the Instruments result of each run: a list of {phase: (fps, missed a second)}."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise InputError(f"cannot read {path}: {error}") from error
    runs = data.get("runs") if isinstance(data, dict) else None
    if not isinstance(runs, list) or not runs:
        raise InputError(f"{path}: no runs")
    results = []
    for index, run in enumerate(runs, start=1):
        result = {}
        for phase in GATED:
            part = run.get(phase) if isinstance(run, dict) else None
            if not isinstance(part, dict) or any(field not in part for field in HITCH_FIELDS):
                raise InputError(f"{path}: run {index} has no {phase} phase")
            where = f"{path}: run {index} {phase}"
            numbers([(field, part[field]) for field in ("seconds", "presented", "periodMs")],
                    where)
            hitches = part["hitchesMs"]
            if not isinstance(hitches, list):
                raise InputError(f"{where}: hitchesMs is not a list")
            numbers([("a hitch", hitch) for hitch in hitches], where)
            seconds = part["seconds"]
            period = part["periodMs"]
            if seconds <= 0 or period <= 0:
                raise InputError(f"{where}: a phase of no time")
            # Each hitch: its time divided by the display period, rounded. Halves round up.
            missed = sum(math.floor(hitch / period + 0.5) for hitch in hitches)
            result[phase] = (part["presented"] / seconds, missed / seconds)
        results.append(result)
    return results


def counter_values(sample):
    """Return the values of one phase of one run, from the frame counter of the app."""
    seconds = sample["seconds"]
    measured = max(0.001, seconds - sample["excludedSeconds"])
    return {
        "seconds": seconds,
        "fps": sample["frames"] / measured,
        "missed": sample["missed"] / seconds,
        "app": sample["appFootprint"] / MIB,
        "children": sample["childFootprint"] / MIB,
        "total": (sample["appFootprint"] + sample["childFootprint"]) / MIB,
        "cpu": sample["appCPUSeconds"] / seconds * 100,
        "instructions": sample["appInstructions"] / seconds / 1e6,
    }


def median_of(runs, phase, key):
    return statistics.median(counter_values(run[phase])[key] for run in runs)


def print_table(runs):
    phases = list(runs[0])
    for run in runs[1:]:
        phases += [phase for phase in run if phase not in phases]
    header = ("phase", "secs", "fps", "missed/s", "app MB", "child MB", "total MB", "CPU %",
              "M instr/s")
    print("  ".join(f"{name:>9}" if i else f"{name:<9}" for i, name in enumerate(header)))
    keys = ("seconds", "fps", "missed", "app", "children", "total", "cpu", "instructions")
    for phase in phases:
        having = [run for run in runs if phase in run]
        values = [median_of(having, phase, key) for key in keys]
        cells = [f"{phase:<9}"] + [f"{value:>9.2f}" for value in values]
        print("  ".join(cells))


def gate_line(name, text, passed):
    print(f"gate {name}: {text}: {'PASS' if passed else 'FAIL'}")
    return passed


def main(argv):
    hitches_paths = []
    paths = []
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--hitches":
            if not args:
                raise InputError("--hitches needs a file")
            hitches_paths.append(args.pop(0))
        else:
            paths.append(arg)
    if not paths:
        raise InputError("usage: summary.py [--hitches FILE]... RESULTS.jsonl...")
    runs = [read_run(path) for path in paths]
    hitches = [result for path in hitches_paths for result in read_hitches(path)]

    print(f"runs: {len(runs)} (the median of each value)")
    print_table(runs)
    passed = True
    counter = {
        phase: (median_of(runs, phase, "fps"), median_of(runs, phase, "missed"))
        for phase in GATED
    }
    if hitches:
        source = "Instruments"
        gated = {
            phase: (
                statistics.median(result[phase][0] for result in hitches),
                statistics.median(result[phase][1] for result in hitches),
            )
            for phase in GATED
        }
    else:
        source = "frame counter"
        gated = counter
    for phase in GATED:
        fps, missed = gated[phase]
        passed &= gate_line(f"{phase} fps ({source})", f"{fps:.2f} (at least {MIN_FPS:g})",
                            fps >= MIN_FPS)
        passed &= gate_line(
            f"{phase} missed frames ({source})",
            f"{missed:.2f} a second (at most {MAX_MISSED:.1f})", missed <= MAX_MISSED)
    highest = statistics.median(
        max(counter_values(sample)["total"] for sample in run.values()) for run in runs)
    passed &= gate_line(
        "footprint",
        f"{highest:.1f} MB for the app and its children (under {MAX_FOOTPRINT_MB:g})",
        highest < MAX_FOOTPRINT_MB)
    if hitches:
        parts = [f"{phase} {counter[phase][0]:.2f} fps, {counter[phase][1]:.2f} missed a second"
                 for phase in GATED]
        print(f"second result (frame counter): {'; '.join(parts)}")
    print(f"result: {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except InputError as error:
        print(f"summary.py: {error}", file=sys.stderr)
        sys.exit(2)
