#!/bin/sh
# Self-test of the bench summary (tools/bench/summary.py) and of the hitch converter
# (tools/bench/hitches.py).
#
# The script writes fixture results files to a temp folder: a set of runs that passes each gate,
# a set for each gate that fails it, an Instruments hitch table that passes and one that fails,
# and files that summary.py must refuse. It runs summary.py on each and checks the exit code and
# the gate lines. Then it writes a fixture export of xctrace (the form of xctrace export, with
# the values that repeat given by ref) and checks the result of hitches.py. It starts no app and
# reads no file outside the temp folder.
#
# Exit 0: each case gave the expected result. The script prints PASS.
# Exit 1: a case failed. The script prints the case and the output of summary.py.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $1"
    exit 1
}

mib=1048576

# Writes one results file: one line for each phase of the gate plan.
# Arguments: the file, the frames and the missed frames of the drag phase (12 s), the frames
# and the missed frames of the resize phase (8 s), the footprint of the app and the footprint
# of the children, in MB.
run_file() {
    app=$(($6 * mib))
    children=$(($7 * mib))
    : >"$1"
    for row in start:10:1199:2 quiet:4:479:1 idle:12:1438:4 warm:6:719:2 stream:12:1436:6 \
        "drag:12:$2:$3" "resize:8:$4:$5" typeprep:3:359:1 typing:25:2990:12; do
        IFS=: read -r phase seconds frames missed <<EOF
$row
EOF
        printf '{"appCPUSeconds":%s,"appFootprint":%s,"appInstructions":%s,"childFootprint":%s,' \
            "0.5" "$app" 900000000 "$children" >>"$1"
        printf '"excludedSeconds":0.01,"frames":%s,"missed":%s,"phase":"%s","seconds":%s}\n' \
            "$frames" "$missed" "$phase" "$seconds" >>"$1"
    done
}

# Runs summary.py with the arguments. Sets out and code.
summary() {
    out=$(python3 -I "$here/summary.py" "$@" 2>&1)
    code=$?
}

# summary.py must exit with the code. Arguments: the case, the code, the arguments.
expect_code() {
    name=$1
    want=$2
    shift 2
    summary "$@"
    [ "$code" -eq "$want" ] || fail "$name: expected exit $want, got $code: $out"
}

# The output must hold the line. Arguments: the case and the text of the line.
expect_line() {
    printf '%s\n' "$out" | grep -q -F -x -- "$2" || fail "$1: no line \"$2\": $out"
}

# Three runs that pass each gate: drag about 119.9 fps and 0.83 missed frames a second, resize
# 119.9 fps and 1.0, and 240 MB for the app and its children. The fps leaves out the excluded
# seconds (0.01 s in each phase).
for n in 1 2 3; do
    run_file "$tmp/pass-$n.jsonl" 1438 10 958 8 200 40
done
pass="$tmp/pass-1.jsonl $tmp/pass-2.jsonl $tmp/pass-3.jsonl"
# shellcheck disable=SC2086
expect_code "passing runs" 0 $pass
expect_line "passing runs" "runs: 3 (the median of each value)"
expect_line "passing runs" "gate drag fps (frame counter): 119.93 (at least 118): PASS"
expect_line "passing runs" \
    "gate drag missed frames (frame counter): 0.83 a second (at most 2.0): PASS"
expect_line "passing runs" "gate resize fps (frame counter): 119.90 (at least 118): PASS"
expect_line "passing runs" \
    "gate resize missed frames (frame counter): 1.00 a second (at most 2.0): PASS"
expect_line "passing runs" \
    "gate footprint: 240.0 MB for the app and its children (under 300): PASS"
expect_line "passing runs" "result: PASS"

# The median decides: one bad run of three does not fail a gate.
run_file "$tmp/bad-one.jsonl" 1300 40 800 30 290 40
expect_code "one bad run" 0 "$tmp/pass-1.jsonl" "$tmp/pass-2.jsonl" "$tmp/bad-one.jsonl"

# Each gate fails alone.
run_file "$tmp/drag-fps.jsonl" 1400 10 958 8 200 40
expect_code "drag fps" 1 "$tmp/drag-fps.jsonl"
expect_line "drag fps" "gate drag fps (frame counter): 116.76 (at least 118): FAIL"
expect_line "drag fps" "result: FAIL"
run_file "$tmp/drag-missed.jsonl" 1438 30 958 8 200 40
expect_code "drag missed" 1 "$tmp/drag-missed.jsonl"
expect_line "drag missed" \
    "gate drag missed frames (frame counter): 2.50 a second (at most 2.0): FAIL"
run_file "$tmp/resize-fps.jsonl" 1438 10 930 8 200 40
expect_code "resize fps" 1 "$tmp/resize-fps.jsonl"
expect_line "resize fps" "gate resize fps (frame counter): 116.40 (at least 118): FAIL"
run_file "$tmp/resize-missed.jsonl" 1438 10 958 20 200 40
expect_code "resize missed" 1 "$tmp/resize-missed.jsonl"
expect_line "resize missed" \
    "gate resize missed frames (frame counter): 2.50 a second (at most 2.0): FAIL"
run_file "$tmp/footprint.jsonl" 1438 10 958 8 270 30
expect_code "footprint" 1 "$tmp/footprint.jsonl"
expect_line "footprint" \
    "gate footprint: 300.0 MB for the app and its children (under 300): FAIL"
# Each other gate of these files passes.
expect_line "footprint" "gate drag fps (frame counter): 119.93 (at least 118): PASS"

# The Instruments hitch table (pre-flight ruling 11). Missed frames a second: the sum of each
# hitch time divided by the display period, rounded, then divided by the seconds of the phase.
# The fps: the presented frames divided by the seconds. The gate then uses this result, and
# summary.py prints the counter result as the second result.
# The drag hitches give 2, 3 and 1 missed frames, and the resize hitches 1 and 1.
cat >"$tmp/hitches-pass.json" <<'EOF'
{"runs": [
  {"drag": {"seconds": 12, "presented": 1436, "periodMs": 8.333,
            "hitchesMs": [16.6, 25.1, 7.0]},
   "resize": {"seconds": 8, "presented": 958, "periodMs": 8.333, "hitchesMs": [8.4, 8.4]}}
]}
EOF
# The drag hitches give 12, 12 and 6 missed frames.
cat >"$tmp/hitches-fail.json" <<'EOF'
{"runs": [
  {"drag": {"seconds": 12, "presented": 1400, "periodMs": 8.333,
            "hitchesMs": [100, 100, 50]},
   "resize": {"seconds": 8, "presented": 958, "periodMs": 8.333, "hitchesMs": []}}
]}
EOF
# The counter fails the drag (116.76 fps), but Instruments passes it: the run passes.
expect_code "instruments pass" 0 --hitches "$tmp/hitches-pass.json" "$tmp/drag-fps.jsonl"
expect_line "instruments pass" "gate drag fps (Instruments): 119.67 (at least 118): PASS"
expect_line "instruments pass" "gate resize fps (Instruments): 119.75 (at least 118): PASS"
expect_line "instruments pass" \
    "gate drag missed frames (Instruments): 0.50 a second (at most 2.0): PASS"
expect_line "instruments pass" \
    "gate resize missed frames (Instruments): 0.25 a second (at most 2.0): PASS"
second="second result (frame counter): drag 116.76 fps, 0.83 missed a second;"
second="$second resize 119.90 fps, 1.00 missed a second"
expect_line "instruments pass" "$second"
expect_line "instruments pass" "result: PASS"
# The counter passes, but Instruments fails the drag (30 missed frames in 12 s).
# shellcheck disable=SC2086
expect_code "instruments fail" 1 --hitches "$tmp/hitches-fail.json" $pass
expect_line "instruments fail" "gate drag fps (Instruments): 116.67 (at least 118): FAIL"
expect_line "instruments fail" \
    "gate drag missed frames (Instruments): 2.50 a second (at most 2.0): FAIL"
expect_line "instruments fail" "result: FAIL"

# Halves round up (review fix 2): with a period of 10 ms, a hitch of 25 ms gives 3 missed frames
# and a hitch of 5 ms gives 1, so the resize gives 4 missed frames in 8 s.
cat >"$tmp/hitches-half.json" <<'EOF'
{"runs": [
  {"drag": {"seconds": 12, "presented": 1436, "periodMs": 8.333, "hitchesMs": []},
   "resize": {"seconds": 8, "presented": 958, "periodMs": 10, "hitchesMs": [25, 5]}}
]}
EOF
expect_code "halves round up" 0 --hitches "$tmp/hitches-half.json" "$tmp/pass-1.jsonl"
expect_line "halves round up" \
    "gate resize missed frames (Instruments): 0.50 a second (at most 2.0): PASS"

# run.sh --trace writes one hitch file for each run. The runs of all the --hitches files count:
# fail, pass and pass give the pass values (the median), and fail, fail and pass fail.
fail_file="$tmp/hitches-fail.json"
pass_file="$tmp/hitches-pass.json"
expect_code "three files pass" 0 --hitches "$fail_file" --hitches "$pass_file" \
    --hitches "$pass_file" "$tmp/pass-1.jsonl"
expect_line "three files pass" "gate drag fps (Instruments): 119.67 (at least 118): PASS"
expect_line "three files pass" \
    "gate drag missed frames (Instruments): 0.50 a second (at most 2.0): PASS"
expect_code "three files fail" 1 --hitches "$fail_file" --hitches "$fail_file" \
    --hitches "$pass_file" "$tmp/pass-1.jsonl"
expect_line "three files fail" \
    "gate drag missed frames (Instruments): 2.50 a second (at most 2.0): FAIL"

# Input that summary.py refuses: no file, a missing file, a line that is not JSON, a sample with
# no frames field, a run with no drag phase and a hitch table with no resize phase. A value that
# is not a number (a bool, a text or null) is bad input too, never an error of Python.
expect_code "no file" 2
expect_code "missing file" 2 "$tmp/missing.jsonl"
printf '%s\n' 'not json' >"$tmp/not-json.jsonl"
expect_code "not JSON" 2 "$tmp/not-json.jsonl"
grep -v '"phase":"drag"' "$tmp/pass-1.jsonl" >"$tmp/no-drag.jsonl"
expect_code "no drag phase" 2 "$tmp/no-drag.jsonl"
sed -e 's/"frames":[0-9]*,//' "$tmp/pass-1.jsonl" >"$tmp/no-frames.jsonl"
expect_code "no frames field" 2 "$tmp/no-frames.jsonl"
cat >"$tmp/hitches-bad.json" <<'EOF'
{"runs": [{"drag": {"seconds": 12, "presented": 1, "periodMs": 8.3, "hitchesMs": []}}]}
EOF
expect_code "no resize hitches" 2 --hitches "$tmp/hitches-bad.json" "$tmp/pass-1.jsonl"
n=0
for change in 's/"frames":[0-9]*/"frames":true/' 's/"seconds":[0-9.]*/"seconds":"3"/' \
    's/"missed":[0-9]*/"missed":null/' 's/"appFootprint":[0-9]*/"appFootprint":false/' \
    's/"phase":"[a-z]*"/"phase":7/'; do
    n=$((n + 1))
    sed -e "$change" "$tmp/pass-1.jsonl" >"$tmp/bad-value-$n.jsonl"
    expect_code "bad value $n" 2 "$tmp/bad-value-$n.jsonl"
    printf '%s\n' "$out" | grep -q -F "Traceback" && fail "bad value $n: a Python error: $out"
done
for part in '"seconds": true' '"presented": "1"' '"periodMs": null' '"hitchesMs": [true]' \
    '"hitchesMs": 5' '"hitchesMs": ["8"]'; do
    n=$((n + 1))
    cat >"$tmp/hitches-value-$n.json" <<EOF
{"runs": [
  {"drag": {"seconds": 12, "presented": 1436, "periodMs": 8.333, "hitchesMs": []},
   "resize": {"seconds": 8, "presented": 958, "periodMs": 8.333, "hitchesMs": [], $part}}
]}
EOF
    expect_code "bad hitch value $n" 2 --hitches "$tmp/hitches-value-$n.json" "$tmp/pass-1.jsonl"
    printf '%s\n' "$out" | grep -q -F "Traceback" && fail "bad hitch value $n: a Python error: $out"
done

# The hitch converter. The time base is 125/3 and the mach time of the trace time 0 is 3e9, so
# the trace time 0 is the host time 125 s. The drag starts at the host time 130 s (the trace
# time 5 s) and the resize at 130.1 s (5.1 s). Each phase has 0.05 s. The frames come each
# 8333333 ns from 4.99 s to 5.157 s, so each phase has 6 frames, and the trace has frames
# before and after each phase. The frame at 5.023 s of the drag has a hitch of 16666666 ns.
export="$tmp/export"
mkdir -p "$export"
cat >"$export/time-info.xml" <<'XML'
<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[1]'><schema name="time-info">
<col><mnemonic>update-time</mnemonic><name>Update Time</name></col>
<col><mnemonic>mabs-epoch</mnemonic><name>Mach Absolute Epoch</name></col>
<col><mnemonic>mct-epoch</mnemonic><name>Mach Continuous Epoch</name></col>
<col><mnemonic>timebase-info</mnemonic><name>Timebase</name></col>
<col><mnemonic>trace-start-time</mnemonic><name>Trace Start</name></col>
</schema>
<row><sample-time id="1" fmt="00:00.000.000">0</sample-time><mach-absolute-time id="2"
fmt="3000000000">3000000000</mach-absolute-time><mach-continuous-time id="3"
fmt="3000000000">3000000000</mach-continuous-time><mach-timebase-info id="4"
fmt="125/3">125/3</mach-timebase-info><time-since-epoch id="5" fmt="0">0</time-since-epoch></row>
</node></trace-query-result>
XML
cat >"$export/toc.xml" <<'XML'
<?xml version="1.0"?>
<trace-toc><run number="1"><info><summary><start-date>2026-11-16T07:00:00.000+00:00</start-date>
<duration>25.0</duration></summary></info><data>
<table schema="hitches-lifetime-interval"/><table schema="time-info"/></data></run></trace-toc>
XML
{
    echo '<?xml version="1.0"?>'
    echo '<trace-query-result>'
    echo "<node xpath='//trace-toc[1]/run[1]/data[1]/table[2]'>"
    echo '<schema name="hitches-lifetime-interval">'
    for column in start duration presentation-time hitch-duration refresh-interval; do
        echo "<col><mnemonic>$column</mnemonic><name>$column</name></col>"
    done
    echo '</schema>'
    k=0
    while [ "$k" -le 20 ]; do
        time=$((4990000000 + k * 8333333))
        hitch='<duration ref="h0"/>'
        [ "$k" -eq 0 ] && hitch='<duration id="h0" fmt="0">0</duration>'
        [ "$k" -eq 4 ] && hitch='<duration fmt="16.67 ms">16666666</duration>'
        period='<duration ref="p"/>'
        [ "$k" -eq 0 ] && period='<duration id="p" fmt="8.33 ms">8333333</duration>'
        printf '<row><start-time fmt="t">%s</start-time><sentinel/>' "$((time - 20000000))"
        printf '<event-time fmt="t">%s</event-time>%s%s</row>\n' "$time" "$hitch" "$period"
        k=$((k + 1))
    done
    echo '</node></trace-query-result>'
} >"$export/hitches-lifetime-interval.xml"
start_date=$(python3 -I -c 'import datetime; print(datetime.datetime.fromisoformat(
    "2026-11-16T07:00:00.000+00:00").timestamp())')
drag_date=$(python3 -I -c "print($start_date + 5.0)")
resize_date=$(python3 -I -c "print($start_date + 5.1)")
{
    printf '{"phase":"stream","seconds":12,"start":118,"startDate":%s}\n' "$start_date"
    printf '{"phase":"drag","seconds":0.05,"start":130.0,"startDate":%s}\n' "$drag_date"
    printf '{"phase":"resize","seconds":0.05,"start":130.1,"startDate":%s}\n' "$resize_date"
} >"$tmp/traced.jsonl"
runs='"runs": [{"drag": {"seconds": 0.05, "presented": 6, "periodMs": 8.333333,'
runs="$runs"' "hitchesMs": [16.666666]}, "resize": {"seconds": 0.05, "presented": 6,'
runs="$runs"' "periodMs": 8.333333, "hitchesMs": []}}]}'
want="{\"clock\": \"time-info\", $runs"
got=$(python3 -I "$here/hitches.py" "$export" "$tmp/traced.jsonl" 2>&1) ||
    fail "hitches: exit $?: $got"
[ "$got" = "$want" ] || fail "hitches: expected $want, got $got"
# With no time-info table, the start date of the trace and the wall time of each phase give the
# same windows.
mv "$export/time-info.xml" "$tmp/time-info.xml"
want_date="{\"clock\": \"start-date\", $runs"
got=$(python3 -I "$here/hitches.py" "$export" "$tmp/traced.jsonl" 2>&1) ||
    fail "hitches by date: exit $?: $got"
[ "$got" = "$want_date" ] || fail "hitches by date: expected $want_date, got $got"
# A time-info table with no rows gives the start date too.
printf '%s\n' '<?xml version="1.0"?><trace-query-result></trace-query-result>' \
    >"$export/time-info.xml"
got=$(python3 -I "$here/hitches.py" "$export" "$tmp/traced.jsonl" 2>&1) ||
    fail "hitches with an empty time-info: exit $?: $got"
[ "$got" = "$want_date" ] || fail "hitches with an empty time-info: expected $want_date: $got"
mv "$tmp/time-info.xml" "$export/time-info.xml"
# The output is the input of summary.py --hitches. The 2 missed frames of the hitch in 0.05 s
# give 40 missed frames a second.
printf '%s\n' "$got" >"$tmp/traced-hitches.json"
expect_code "hitches into summary" 1 --hitches "$tmp/traced-hitches.json" "$tmp/pass-1.jsonl"
expect_line "hitches into summary" "gate drag fps (Instruments): 120.00 (at least 118): PASS"
expect_line "hitches into summary" \
    "gate drag missed frames (Instruments): 40.00 a second (at most 2.0): FAIL"
# A phase with no frame gives no result (exit 2), not a pass: here the clock is 10 s late.
sed -e 's/"start":130.0,/"start":140.0,/' "$tmp/traced.jsonl" >"$tmp/late.jsonl"
got=$(python3 -I "$here/hitches.py" "$export" "$tmp/late.jsonl" 2>&1)
code=$?
[ "$code" -eq 2 ] || fail "hitches with no frame: expected exit 2, got $code: $got"
printf '%s\n' "$got" | grep -q -F "no frame in the drag phase" ||
    fail "hitches with no frame: $got"
# A trace that ends before the end of the resize does not cover it: no result.
lifetime="$export/hitches-lifetime-interval.xml"
cp "$lifetime" "$tmp/lifetime.xml"
grep -v -F '>5156666660<' "$tmp/lifetime.xml" >"$lifetime"
got=$(python3 -I "$here/hitches.py" "$export" "$tmp/traced.jsonl" 2>&1)
code=$?
[ "$code" -eq 2 ] || fail "hitches cut short: expected exit 2, got $code: $got"
printf '%s\n' "$got" | grep -q -F "does not cover the resize phase" ||
    fail "hitches cut short: $got"
# The frames of two displays at the same times in one table: twice the frames that one display
# can show.
{
    sed -e '/<\/node>/d' "$tmp/lifetime.xml"
    grep -F '<row>' "$tmp/lifetime.xml"
    echo '</node></trace-query-result>'
} >"$lifetime"
got=$(python3 -I "$here/hitches.py" "$export" "$tmp/traced.jsonl" 2>&1)
code=$?
[ "$code" -eq 2 ] || fail "hitches of two displays: expected exit 2, got $code: $got"
printf '%s\n' "$got" | grep -q -F "more than the display can show" ||
    fail "hitches of two displays: $got"
cp "$tmp/lifetime.xml" "$lifetime"
# The name of the table in a real trace: hitches-frame-lifetimes. It comes first.
cp "$lifetime" "$export/hitches-frame-lifetimes.xml"
printf '%s\n' '<?xml version="1.0"?><trace-query-result></trace-query-result>' >"$lifetime"
want_time="{\"clock\": \"time-info\", $runs"
got=$(python3 -I "$here/hitches.py" "$export" "$tmp/traced.jsonl" 2>&1) ||
    fail "hitches-frame-lifetimes: exit $?: $got"
[ "$got" = "$want_time" ] || fail "hitches-frame-lifetimes: expected $want_time, got $got"
# A table with no column hitch-duration gives no result, not a pass with no hitch.
sed -e 's/<mnemonic>hitch-duration</<mnemonic>hitch-time</' "$tmp/lifetime.xml" \
    >"$export/hitches-frame-lifetimes.xml"
got=$(python3 -I "$here/hitches.py" "$export" "$tmp/traced.jsonl" 2>&1)
code=$?
[ "$code" -eq 2 ] || fail "hitches with no hitch column: expected exit 2, got $code: $got"
printf '%s\n' "$got" | grep -q -F "not hitch-duration" || fail "hitches with no hitch column: $got"
rm -f "$export/hitches-frame-lifetimes.xml"
cp "$tmp/lifetime.xml" "$lifetime"
# A results file with no start of the phase is bad input.
sed -e 's/"start":130.0,//' "$tmp/traced.jsonl" >"$tmp/no-start.jsonl"
got=$(python3 -I "$here/hitches.py" "$export" "$tmp/no-start.jsonl" 2>&1)
[ "$?" -eq 2 ] || fail "hitches with no start: expected exit 2: $got"

echo PASS
