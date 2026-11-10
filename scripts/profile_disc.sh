#!/bin/sh
# usage: discprof.sh <label>
SIM=CA9452DF-8ADA-4C5F-82EA-B629E6B318F7
APP=${APP:-/tmp/simbuild216/Build/Products/Release-iphonesimulator/Vinyl.app}
xcrun simctl terminate $SIM com.zhaolegs.Vinyl >/dev/null 2>&1
xcrun simctl install $SIM $APP; xcrun simctl privacy $SIM grant media-library com.zhaolegs.Vinyl >/dev/null 2>&1
D=$(xcrun simctl get_app_container $SIM com.zhaolegs.Vinyl data)
rm -f "$D/Documents/disc-profile.json"
xcrun simctl launch $SIM com.zhaolegs.Vinyl --profile-disc >/dev/null
for i in $(seq 1 60); do [ -f "$D/Documents/disc-profile.json" ] && break; sleep 1; done
xcrun simctl io $SIM screenshot /tmp/discprof_$1.png >/dev/null 2>&1
cp "$D/Documents/disc-profile.json" /tmp/discprof_$1.json && cat /tmp/discprof_$1.json
xcrun simctl terminate $SIM com.zhaolegs.Vinyl
