# embed-services-dashboard
EMBED Services Dashboard
Dashboard for EMBED based Arcade Locations. In partner with Zach Tristan and myself, Mike Adams. We are creating this to make it easier for troubleshooting and notification of issues as they happen rather than long after. 

Packaged EXE self-updates require a GitHub Release tagged to match `version.json`'s `releaseTag` and containing the executable named by `exeAsset`. The release asset's SHA-256 digest must be available from GitHub release metadata, or be set as `exeSha256` in `version.json`. Users already running an older EXE must replace it manually once with a build containing the EXE updater; subsequent releases can install through the dashboard.
