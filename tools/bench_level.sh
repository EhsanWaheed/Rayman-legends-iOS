#!/bin/zsh
# Runs the Mac build into the first level of Teensies in Trouble (needs the save that is past the intro), waits until
# the level is steady, records a Metal System Trace and prints the GPU load and the game's frame rate.
#
# usage: tools/bench_level.sh <name> [extra args...]   (environment passes through, e.g. RL_GPU_STATS=1)
set -u
NAME=$1; shift
ROOT=${0:a:h}/..
pkill -9 -f "rayman_legends --game"; while pgrep -f "rayman_legends --game" > /dev/null; do sleep 0.5; done
cd $ROOT/legends/out/build/mac-arm64-release
RL_INPUT_SCRIPT="22:Space,26:Space,30:Space,34:Space,46:Right:1.0,47.2:Space,60:Space,64:Space,74:Right:1.2,74.6:Space" \
    ./rayman_legends --game_data_root=$ROOT/game --log_file=$ROOT/logs/bench-$NAME.log "$@" > /dev/null 2>&1 &
sleep 95
pid=$(pgrep -f "logs/bench-$NAME.log" | head -1)
cpu0=$(ps -o time= -p $pid); sleep 10; cpu1=$(ps -o time= -p $pid)
echo "cpu time over 10 s: $cpu0 -> $cpu1"
rm -rf $ROOT/analysis/bench-$NAME.trace
xcrun xctrace record --template "Metal System Trace" --attach $pid --time-limit 4s \
    --output $ROOT/analysis/bench-$NAME.trace > /dev/null 2>&1
xcrun xctrace export --input $ROOT/analysis/bench-$NAME.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]' > $ROOT/analysis/bench-$NAME.xml 2>/dev/null
python3 $ROOT/tools/gpu_frames.py $ROOT/analysis/bench-$NAME.xml | grep -v "per frame"
grep -E "\[perf\]" $ROOT/logs/bench-$NAME.log | tail -4 | sed -E 's/.*\[perf\]/fps/'
