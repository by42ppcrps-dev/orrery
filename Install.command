#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
echo "Orrery installer"
echo "This builds Orrery on your Mac and installs it in Applications. Your projects and accounts are kept."
echo "The first build can take several minutes."
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then
  echo "Orrery needs macOS 14 or newer. Update macOS before installing."
  read -r -p "Press Return to close. " _orrery_reply
  exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Install Xcode from the Mac App Store, open it once, then run this installer again."
  read -r -p "Press Return to close. " _orrery_reply
  exit 1
fi
_orrery_swift_major="$(xcrun swift --version | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)"
if [ -z "$_orrery_swift_major" ] || [ "$_orrery_swift_major" -lt 6 ]; then
  echo "Orrery needs Swift 6 or newer. Install Xcode 16 or newer, open it once, then select it under Xcode Settings > Locations > Command Line Tools."
  read -r -p "Press Return to close. " _orrery_reply
  exit 1
fi
if ./build-app.sh --install; then
  /usr/bin/open /Applications/Orrery.app
else
  echo "Installation did not finish. The message above explains the next step."
  read -r -p "Press Return to close. " _orrery_reply
  exit 1
fi
