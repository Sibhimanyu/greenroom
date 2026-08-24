# Apptics helper scripts

Taken verbatim from `HelperScripts.zip` in the
[zoho/Apptics 3.3.17 release](https://github.com/zoho/Apptics/releases/tag/3.3.17),
which is the same archive the `Apptics-SDK` CocoaPod downloads.

They are vendored here rather than pulled by a package manager because the SDK
itself comes in over SPM (see `packages:` in `project.yml`), and SPM has no
concept of a build-phase script the way CocoaPods' `script_phase` does. The
official CocoaPods integration would run `./Pods/Apptics-SDK/scripts/run`; the
pre-build phase in `project.yml` runs this copy instead.

`scripts/run` does three things at build time:

1. Writes `AP_INFOPLIST_FILE` into the app's `Info.plist`, which is how the SDK
   finds its config at runtime.
2. Registers the current `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` with
   Apptics and writes the returned IDs back into `apptics-config.plist` under
   `APP_VERSION_META`.
3. Uploads dSYMs, for the configurations named in `--upload-symbols-for-configurations`.

Step 2 means `apptics-config.plist` is REWRITTEN by builds. It is gitignored:
it carries `API_KEY`, and this repository is public.

Updating: download the `HelperScripts.zip` for the new tag and replace
`scripts/` wholesale. Keep the tag here in step with the `exactVersion` pinned
in `project.yml` - the scripts post the SDK id from `scripts/sdk_info`, so a
mismatch registers the wrong framework version against your app.
