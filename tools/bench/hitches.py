"""Convert the Instruments export of one bench run to the hitch result (phase 3b, Task 5).

Usage: python3 -I tools/bench/hitches.py EXPORT_DIR RESULTS.jsonl

EXPORT_DIR holds the files of `xctrace export` that run.sh --trace writes for one run:
- toc.xml: the table of contents of the trace (--toc).
- time-info.xml: the table time-info (the mach time at the trace time 0 and the time base).
- hitches-frame-lifetimes.xml (the name in a real trace of Xcode 26), else
  hitches-lifetime-interval.xml (the name of the modeler): the frame lifetimes of the template
  "Animation Hitches". Each row is one frame with its presentation time, its hitch time
  (hitch-duration, 0 for no hitch) and the display period (refresh-interval). Each time is in
  nanoseconds. A table with no column hitch-duration, or with no column presentation-time or
  start, gives no result.
RESULTS.jsonl is the results file of the same run. Each sample has the start of its phase: the
host time in seconds (start) and the wall time in seconds since 1970 (startDate).

The script prints {"clock": CLOCK, "runs": [{"drag": PHASE, "resize": PHASE}]}, the input of
summary.py --hitches, with PHASE = {"seconds": s, "presented": n, "periodMs": p,
"hitchesMs": [h, ...]}:
- The window of a phase starts at the host time of its start on the trace clock: the host time
  in nanoseconds less the mach time of the trace time 0 (mabs-epoch) in nanoseconds (CLOCK
  "time-info"). With no time-info table that can be read, the window starts at the wall time of
  the phase less the start date of the trace in toc.xml (CLOCK "start-date").
- presented: the frames whose presentation time is in the window.
- hitchesMs: the hitch time of each frame in the window with a hitch, in milliseconds.
- periodMs: the median display period of the frames in the window.

The first form of this script was not checked against a real trace (Instruments needs the
Developer Tools access, which the night runs did not have). So the script refuses each result
that it cannot trust, and gives no result in place of a false pass:
- a phase with no frame (a wrong table or a wrong clock);
- a phase that the trace does not cover: no frame before the window or none after it (the
  trace started late or ended early);
- a phase with more frames than the display can show (more than 1.05 frames a period: the
  table can hold the frames of more than one display).

Exit 0: the result is on the standard output. Exit 2: the input cannot be read.
"""

import datetime
import json
import os
import re
import statistics
import sys
import xml.etree.ElementTree as ET

PHASES = ("drag", "resize")
LIFETIMES = ("hitches-frame-lifetimes.xml", "hitches-lifetime-interval.xml")
TIME_INFO = "time-info.xml"
TOC = "toc.xml"


class InputError(Exception):
    pass


def read_table(path, required=()):
    """Return the rows of one exported table: a list of {column mnemonic: element}.

    required: groups of column names. The table must have one column of each group.

    xctrace writes each value once with an id, and later rows refer to it with ref.
    """
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        raise InputError(f"cannot read {path}: {error}") from error
    by_id = {}
    for element in root.iter():
        if element.get("id") is not None:
            by_id[element.get("id")] = element
    schema = root.find(".//schema")
    if schema is None:
        raise InputError(f"{path}: no schema")
    columns = [column.findtext("mnemonic") for column in schema.findall("col")]
    if required and not all(any(name in columns for name in need) for need in required):
        raise InputError(f"{path}: the columns are {', '.join(map(str, columns))}, not "
                         f"{' and '.join(' or '.join(need) for need in required)}")
    rows = []
    for row in root.iter("row"):
        values = {}
        for column, element in zip(columns, list(row)):
            ref = element.get("ref")
            if ref is not None:
                if ref not in by_id:
                    raise InputError(f"{path}: a value refers to the missing id {ref}")
                element = by_id[ref]
            values[column] = element
        rows.append(values)
    return rows


def number(element):
    """The integer value of an element, or None for a sentinel or a text that is not a number."""
    if element is None or element.tag == "sentinel":
        return None
    text = "".join(element.itertext()).strip()
    try:
        return int(text)
    except ValueError:
        try:
            return int(float(text))
        except ValueError:
            return None


def epoch_nanoseconds(path):
    """The mach time of the trace time 0, in nanoseconds (mabs-epoch with timebase-info)."""
    rows = read_table(path)
    if not rows:
        raise InputError(f"{path}: no rows")
    row = rows[-1]
    epoch = number(row.get("mabs-epoch"))
    if epoch is None:
        raise InputError(f"{path}: no mabs-epoch")
    timebase = row.get("timebase-info")
    numer, denom = 1, 1
    if timebase is not None:
        text = " ".join(timebase.itertext()) + " " + (timebase.get("fmt") or "")
        parts = [int(value) for value in re.findall(r"\d+", text)]
        if len(parts) >= 2 and parts[1] > 0:
            numer, denom = parts[0], parts[1]
    return epoch * numer / denom


def toc_start(path):
    """The start date of the first run of the trace, in seconds since 1970."""
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        raise InputError(f"cannot read {path}: {error}") from error
    text = root.findtext(".//run/info/summary/start-date")
    if not text:
        raise InputError(f"{path}: no start-date")
    try:
        return datetime.datetime.fromisoformat(text.strip()).timestamp()
    except ValueError as error:
        raise InputError(f"{path}: the start-date {text!r} is not a date") from error


def read_samples(path):
    """The samples of the drag and the resize: {phase: sample}."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = [line for line in handle.read().splitlines() if line.strip()]
    except OSError as error:
        raise InputError(f"cannot read {path}: {error}") from error
    samples = {}
    for line in lines:
        try:
            sample = json.loads(line)
        except json.JSONDecodeError as error:
            raise InputError(f"{path}: not JSON: {error}") from error
        if isinstance(sample, dict) and sample.get("phase") in PHASES:
            samples[sample["phase"]] = sample
    for phase in PHASES:
        sample = samples.get(phase)
        if sample is None:
            raise InputError(f"{path}: no {phase} phase")
        for field in ("seconds", "start", "startDate"):
            value = sample.get(field)
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                raise InputError(f"{path}: the {phase} phase has no number {field}")
    return samples


def frames(rows):
    """Each frame: (presentation time, hitch time, display period), in nanoseconds."""
    result = []
    for row in rows:
        time = number(row.get("presentation-time"))
        if time is None:
            time = number(row.get("start"))
        if time is None:
            continue
        hitch = number(row.get("hitch-duration")) or 0
        period = number(row.get("refresh-interval"))
        result.append((time, hitch, period))
    return result


def phase_starts(export_dir, samples):
    """The start of each phase on the trace clock in nanoseconds, and the name of the clock."""
    time_info = os.path.join(export_dir, TIME_INFO)
    if os.path.exists(time_info):
        try:
            epoch = epoch_nanoseconds(time_info)
        except InputError:
            epoch = None
        if epoch is not None:
            return {phase: samples[phase]["start"] * 1e9 - epoch for phase in PHASES}, "time-info"
    start_date = toc_start(os.path.join(export_dir, TOC))
    starts = {phase: (samples[phase]["startDate"] - start_date) * 1e9 for phase in PHASES}
    return starts, "start-date"


def convert(export_dir, results_path):
    samples = read_samples(results_path)
    starts, clock = phase_starts(export_dir, samples)
    paths = [os.path.join(export_dir, name) for name in LIFETIMES]
    path = next((path for path in paths if os.path.exists(path) and os.path.getsize(path) > 100),
                paths[-1])
    required = (("hitch-duration",), ("presentation-time", "start"))
    lifetimes = frames(read_table(path, required))
    run = {}
    for phase in PHASES:
        seconds = samples[phase]["seconds"]
        begin = starts[phase]
        end = begin + seconds * 1e9
        inside = [frame for frame in lifetimes if begin <= frame[0] < end]
        if not inside:
            raise InputError(f"the trace has no frame in the {phase} phase")
        if not any(frame[0] < begin for frame in lifetimes) or not any(
                frame[0] >= end for frame in lifetimes):
            raise InputError(f"the trace does not cover the {phase} phase")
        periods = [frame[2] for frame in inside if frame[2]]
        period_ms = statistics.median(periods) / 1e6 if periods else 1000 / 120
        if len(inside) > 1.05 * seconds * 1000 / period_ms:
            raise InputError(
                f"the {phase} phase has {len(inside)} frames in {seconds} s, more than the "
                f"display can show at {period_ms:.3f} ms a frame")
        run[phase] = {
            "seconds": seconds,
            "presented": len(inside),
            "periodMs": period_ms,
            "hitchesMs": [frame[1] / 1e6 for frame in inside if frame[1] > 0],
        }
    return {"clock": clock, "runs": [run]}


def main(argv):
    if len(argv) != 2:
        raise InputError("usage: hitches.py EXPORT_DIR RESULTS.jsonl")
    print(json.dumps(convert(argv[0], argv[1])))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except InputError as error:
        print(f"hitches.py: {error}", file=sys.stderr)
        sys.exit(2)
