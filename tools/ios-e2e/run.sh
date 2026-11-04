#!/bin/zsh
# Phone UI end to end (docs/UI.md): side agents on this Mac, two test windows,
# a simulator, and UITests/FlowUITests.swift tapping and swiping through it.
#
#   tools/ios-e2e/run.sh [simulator name]      (default: iPhone 17 Pro)
#
# Nothing here touches the installed agent: the Mac agent runs from this
# checkout's build on 18890, the Linux agent on 18990, each with its own state.
set -u
here=${0:A:h}
repo=${here:h:h}
sim=${1:-iPhone 17 Pro}
work=$(mktemp -d /tmp/panes-ios-e2e.XXXXXX)
dd=$work/dd
mkdir -p $work/shots $work/mac-state $work/linux-state
pids=()
tmux_before=$(tmux ls -F '#S' 2>/dev/null | sort)

cleanup() {
  for p in $pids; do kill $p 2>/dev/null; done
  xcrun simctl spawn "$sim" log show --last 10m --style compact --predicate 'process == "Panes"' > $work/app.log 2>/dev/null
  xcrun simctl shutdown "$sim" 2>/dev/null
  # Only the tmux sessions this run made.
  for s in $(comm -13 <(print -l $tmux_before) <(tmux ls -F '#S' 2>/dev/null | sort)); do
    [[ $s == panes-* ]] && tmux kill-session -t $s
  done
}
trap cleanup EXIT

echo "building into $dd"
xcodebuild build -project $repo/Panes.xcodeproj -scheme PanesAgent -destination 'platform=macOS' \
  -derivedDataPath $dd -quiet || exit 1
swiftc -O $repo/tools/web-e2e/tone_window.swift -o $work/tone_window || exit 1

PANES_PORT=18890 PANES_WEB_PORT=18891 PANES_STATE_DIR=$work/mac-state \
  "$dd/Build/Products/Debug/Panes Agent.app/Contents/MacOS/Panes Agent" > $work/mac-agent.log 2>&1 &
pids+=($!)
PANES_PORT=18990 PANES_WEB_PORT=18991 PANES_STATE_DIR=$work/linux-state \
  python3 $repo/linux/panes_agent.py > $work/linux-agent.log 2>&1 &
pids+=($!)
$work/tone_window panes-ui-a 600 >/dev/null 2>&1 & pids+=($!)
$work/tone_window panes-ui-b 600 >/dev/null 2>&1 & pids+=($!)
cat > $work/machines.json <<JSON
[
  {"name": "Mac mini", "hosts": ["127.0.0.1:18890"], "color": "#5B9BFF"},
  {"name": "linux-box", "hosts": ["127.0.0.1:18990"], "color": "#F2A33A"}
]
JSON
sleep 3

xcrun simctl boot "$sim" 2>/dev/null
TEST_RUNNER_PANES_MACHINES=$work/machines.json \
TEST_RUNNER_PANES_E2E_AGENTS=127.0.0.1:18890,127.0.0.1:18990 \
TEST_RUNNER_PANES_E2E_SHOTS=$work/shots \
xcodebuild test -project $repo/Panes.xcodeproj -scheme Panes -destination "platform=iOS Simulator,name=$sim" \
  -derivedDataPath $dd -resultBundlePath $work/result.xcresult 2>&1 | grep -E "error|Test Case|Executed|TEST (SUCC|FAIL)|XCTAssert"
rc=${pipestatus[1]}
echo "screenshots: $work/shots"
ls $work/shots
exit $rc
