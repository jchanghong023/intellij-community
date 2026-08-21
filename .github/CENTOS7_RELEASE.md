# CentOS 7 release workflow

This fork adds a manual, build-only release path for Linux x86_64 systems that still use CentOS 7 and glibc 2.17. It does not modify IntelliJ IDEA product source code.

## Release procedure

1. On the fork's `master` branch, use **Sync fork** to bring in the latest upstream changes.
2. Open **Actions** and select **CentOS 7 Release**.
3. Choose **Run workflow**, keep the branch set to `master`, and start the run.
4. Download the resulting archive and SHA-256 file from the GitHub Release created by the workflow.

The workflow rejects runs from branches other than `master` so the release always corresponds to the synchronized default branch.

## Version and tag format

The source tree's `build.txt` determines the IntelliJ platform build baseline. The workflow appends the GitHub Actions run number and run attempt:

```text
<platform-baseline>.<workflow-run-number>.<run-attempt>
```

For example, a `263.SNAPSHOT` source tree built by workflow run 12, attempt 1 receives build number `263.12.1`. The release version and tag are derived from the generated `product-info.json`:

```text
<official-product-version>[-<official-version-suffix>]-<build-number>
```

Example:

```text
2026.3-EAP-263.12.1
```

A source version with a suffix such as `EAP` is published as a GitHub prerelease. A source version without a suffix is published as the latest release.

## CentOS 7 compatibility gate

Current upstream JetBrains Runtime builds no longer target glibc 2.17. The compatibility workflow therefore:

1. Builds the upstream Linux x64 distribution without changing product code.
2. Reads the Java feature version from the synchronized source tree's `runtimeBuild` setting.
3. Downloads the latest GA Eclipse Temurin x64 JDK for that Java feature version and verifies its SHA-256 checksum.
4. Replaces the bundled JetBrains Runtime under `jbr/` with the verified Temurin JDK.
5. Audits Linux x86_64 ELF files, including `.so` files embedded in JARs, and rejects any requirement newer than `GLIBC_2.17`.
6. Runs both `jbr/bin/java -version` and the IDE launcher with `--version` inside a CentOS 7 container.
7. Publishes a GitHub Release only after every gate succeeds.

## Limitations

This is an unofficial compatibility package. Replacing JetBrains Runtime means JetBrains-specific runtime fixes and JCEF-based embedded browser features may be unavailable. The workflow intentionally does not publish the upstream SBOM because it no longer describes the replaced runtime accurately.

`master` in `intellij-community` tracks the next upstream development version, so a release built from `master` is commonly an EAP/development build rather than the latest stable maintenance release.
