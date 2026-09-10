# Firebase configuration

Register the iOS app with bundle identifier `org.boardgamescafe.medinag`, then
place its downloaded `GoogleService-Info.plist` in this directory. The real file
is ignored by Git; XcodeGen includes it automatically when present.

The Firebase configuration contains project identifiers rather than account
credentials, but keeping environment-specific configuration outside source
control matches the web dashboard deployment model.
