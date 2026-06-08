#!/bin/zsh
set -e

LOG="$HOME/Desktop/FixXcodeSimulator.log"
exec > >(tee "$LOG") 2>&1

echo "FixXcodeSimulator started at $(date)"
echo "Log: $LOG"
echo ""

echo "Closing Xcode and Simulator..."
osascript -e 'tell application "Xcode" to quit' 2>/dev/null || true
osascript -e 'tell application "Simulator" to quit' 2>/dev/null || true

echo "Resetting CoreSimulator services..."
sudo killall -9 com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true
sudo killall -9 simdiskimaged 2>/dev/null || true

echo "Cleaning Xcode and Simulator caches..."
rm -rf "$HOME/Library/Developer/CoreSimulator/Caches"
rm -rf "$HOME/Library/Logs/CoreSimulator"
rm -rf "$HOME/Library/Developer/Xcode/DerivedData/create-"*

echo "Selecting Xcode and running first launch setup..."
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch

echo "Scanning and mounting simulator runtimes..."
xcrun simctl runtime scan-and-mount || true

echo "Available simulator runtimes:"
xcrun simctl list runtimes

echo "Building create..."
cd "/Users/fang/Documents/Design"
xcodebuild \
  -project "create.xcodeproj" \
  -scheme "create" \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "/Users/fang/Documents/Design/.xcode-derived" \
  build

echo ""
echo "Done. If the build succeeded, you can reopen create.xcodeproj in Xcode."
echo "Log saved to: $LOG"
read -k 1 "?Press any key to close this window..."
