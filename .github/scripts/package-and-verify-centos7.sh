#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <artifacts-dir> <expected-build-number> <source-snapshot>" >&2
  exit 2
fi

artifacts_dir="$1"
expected_build_number="$2"
source_snapshot="$3"
output_file="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
runner_temp="${RUNNER_TEMP:-/tmp}"
run_id="${GITHUB_RUN_ID:-local}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
work_dir="${runner_temp}/pycharm-centos7-${run_id}-${run_attempt}"
jbr_release_repository="${JBR_RELEASE_REPOSITORY:-jchanghong023/JetBrainsRuntime}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command is unavailable: $1"
}

for command_name in awk cmp curl docker find python3 readelf sha256sum tar; do
  require_command "${command_name}"
done

[[ "${jbr_release_repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail "Invalid JBR release repository: ${jbr_release_repository}"

# PyCharmCommunityProperties.getBaseArtifactName() is "pycharmPC-$buildNumber".
original_artifact="${artifacts_dir}/pycharmPC-${expected_build_number}.tar.gz"
[[ -f "${original_artifact}" ]] || {
  echo "Expected Linux artifact was not produced: ${original_artifact}" >&2
  find "${artifacts_dir}" -maxdepth 1 -type f -printf '%f\n' | sort >&2 || true
  exit 1
}

# LinuxDistributionBuilder publishes an exact sibling copy of the generated
# product-info.json next to the tarball. Verify the archive metadata against it
# instead of maintaining a second, guessed schema in this workflow.
product_info_sibling="${original_artifact}.product-info.json"
[[ -f "${product_info_sibling}" ]] \
  || fail "Official sibling product-info.json is missing: ${product_info_sibling}"

rm -rf "${work_dir}"
mkdir -p "${work_dir}/extracted" "${work_dir}/runtime-unpacked"

product_info_relative="$(
  { tar -tzf "${original_artifact}" || true; } |
    awk '/(^|\/)product-info\.json$/ { print; exit }'
)"
[[ -n "${product_info_relative}" ]] \
  || fail "product-info.json is missing from ${original_artifact}"

product_info_file="${work_dir}/product-info.json"
tar -xOf "${original_artifact}" "${product_info_relative}" > "${product_info_file}"
cmp --silent "${product_info_file}" "${product_info_sibling}" \
  || fail "Internal product-info.json differs from the official sibling metadata"

metadata_env="${work_dir}/metadata.env"
python3 - \
  "${product_info_file}" \
  "${expected_build_number}" \
  "${product_info_relative}" \
  "${source_snapshot}" > "${metadata_env}" <<'PY'
import json
import re
import shlex
import sys
from pathlib import PurePosixPath

product_info_path, expected_build_number, product_info_relative, source_snapshot = sys.argv[1:]
with open(product_info_path, encoding="utf-8") as stream:
    product = json.load(stream)

# These values come directly from PyCharmCommunityProperties and the official
# product-info schema / LinuxDistributionBuilder.
product_code = str(product["productCode"]).strip()
if product_code != "PC":
    raise SystemExit(f"Expected PyCharm productCode='PC', found {product_code!r}")

full_build_number = str(product["buildNumber"]).strip()
if full_build_number != expected_build_number:
    raise SystemExit(
        f"product-info.json contains buildNumber={full_build_number!r}; "
        f"expected {expected_build_number!r}"
    )

product_info_path_in_archive = PurePosixPath(product_info_relative)
if product_info_path_in_archive.is_absolute() or ".." in product_info_path_in_archive.parts:
    raise SystemExit(f"Unsafe product-info.json path: {product_info_relative!r}")

product_root = product_info_path_in_archive.parent
if str(product_root) != "pycharm-oss":
    raise SystemExit(
        f"Expected official PyCharm Linux root 'pycharm-oss', found {str(product_root)!r}"
    )
if product_info_path_in_archive.name != "product-info.json":
    raise SystemExit(f"Unexpected product-info.json path: {product_info_relative!r}")

linux_launches = [
    item
    for item in product.get("launch", [])
    if item.get("os") == "Linux" and item.get("arch") == "amd64"
]
if len(linux_launches) != 1:
    observed = [
        (item.get("os"), item.get("arch"), item.get("launcherPath"))
        for item in product.get("launch", [])
    ]
    raise SystemExit(
        "Expected exactly one official Linux/amd64 launch entry in product-info.json; "
        f"found {len(linux_launches)}. Observed: {observed!r}"
    )

launch = linux_launches[0]
launcher_path = str(launch.get("launcherPath") or "")
java_path = str(launch.get("javaExecutablePath") or "")
if launcher_path != "bin/pycharm":
    raise SystemExit(
        f"Expected official PyCharm Linux launcherPath='bin/pycharm', found {launcher_path!r}"
    )
if java_path != "jbr/bin/java":
    raise SystemExit(
        f"Expected official bundled javaExecutablePath='jbr/bin/java', found {java_path!r}"
    )

for label, relative_path in (("launcherPath", launcher_path), ("javaExecutablePath", java_path)):
    path = PurePosixPath(relative_path)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"Unsafe {label}: {relative_path!r}")

version = str(product["version"]).strip()
version_suffix = str(product.get("versionSuffix") or "").strip()


def slug(value: str) -> str:
    value = re.sub(r"[^0-9A-Za-z._-]+", "-", value).strip("-.")
    if not value:
        raise SystemExit("Version metadata produced an empty release component")
    return value


release_version = slug(version)
if version_suffix:
    release_version += "-" + slug(version_suffix)
tag = f"{release_version}-{slug(expected_build_number)}"

values = {
    "PRODUCT_VERSION": version,
    "VERSION_SUFFIX": version_suffix,
    "FULL_BUILD_NUMBER": full_build_number,
    "PRODUCT_ROOT_RELATIVE": str(product_root),
    "LAUNCHER_PATH": launcher_path,
    "JAVA_PATH": java_path,
    "RELEASE_TAG": tag,
    # This workflow intentionally builds from the synchronized master snapshot.
    # Never advertise such a build as a stable/latest GitHub release merely
    # because ApplicationInfo happens to have an empty versionSuffix.
    "IS_PRERELEASE": "true"
    if version_suffix or source_snapshot.endswith(".SNAPSHOT")
    else "false",
}
for key, value in values.items():
    print(f"{key}={shlex.quote(value)}")
PY
# Values are shell-escaped by the Python code above.
# shellcheck disable=SC1090
source "${metadata_env}"

tar --extract --gzip --file "${original_artifact}" \
  --directory "${work_dir}/extracted" --no-same-owner
product_root="${work_dir}/extracted/${PRODUCT_ROOT_RELATIVE}"
[[ -d "${product_root}" ]] \
  || fail "Unable to determine extracted product root: ${product_root}"

launcher_executable="${product_root}/${LAUNCHER_PATH}"
[[ -x "${launcher_executable}" ]] \
  || fail "PyCharm launcher is missing or not executable: ${launcher_executable}"

# BundledRuntimeImpl parses runtimeBuild as <runtime-version>b<JetBrains-build>.
# Keep the custom CentOS 7 JBR on the same runtime version line. A patch
# extension such as 25.0.4.1 is accepted for a source requirement of 25.0.4,
# but a different update line such as 25.0.5 is rejected.
runtime_build="$(
  awk -F= '$1 == "runtimeBuild" { print $2; exit }' \
    build/dependencies/dependencies.properties
)"
if [[ ! "${runtime_build}" =~ ^([0-9]+(\.[0-9]+)+)b([0-9]+(\.[0-9]+)*)$ ]]; then
  fail "Unable to parse runtimeBuild=${runtime_build}; expected <version>b<build>"
fi
runtime_base_version="${BASH_REMATCH[1]}"
runtime_feature="${runtime_base_version%%.*}"

jbr_releases_api_url="https://api.github.com/repos/${jbr_release_repository}/releases?per_page=100"
jbr_releases_json="${work_dir}/jbr-releases.json"
curl_api_args=(
  --proto '=https'
  --tlsv1.2
  --silent
  --show-error
  --fail
  --location
  --retry 5
  --retry-all-errors
  --header 'Accept: application/vnd.github+json'
  --header 'X-GitHub-Api-Version: 2022-11-28'
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_api_args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
fi

echo "Resolving newest compatible published JBR release from ${jbr_release_repository}"
echo "PyCharm source runtime requirement: ${runtime_build} (compatible JBR line ${runtime_base_version}.x)"
curl "${curl_api_args[@]}" \
  --output "${jbr_releases_json}" \
  "${jbr_releases_api_url}"

jbr_release_env="${work_dir}/jbr-release.env"
python3 - \
  "${jbr_releases_json}" \
  "${runtime_base_version}" \
  "${runtime_feature}" > "${jbr_release_env}" <<'PY'
import json
import re
import shlex
import sys
from pathlib import Path

releases_path, expected_base_version, expected_feature = sys.argv[1:]
releases = json.loads(Path(releases_path).read_text(encoding="utf-8"))
if not isinstance(releases, list):
    raise SystemExit("GitHub releases API returned an unexpected response")

runtime_pattern = re.compile(
    r"^jbr_lb-(?P<version>[0-9]+(?:\.[0-9]+)*)-linux-x64-b[0-9]+(?:\.[0-9]+)*\.tar\.gz$"
)


def compatible_version(version: str) -> bool:
    if version == expected_base_version:
        return True
    return version.startswith(expected_base_version + ".")


selected = None
diagnostics = []
for release in releases:
    if release.get("draft"):
        continue

    assets = release.get("assets") or []
    runtime_matches = []
    observed_runtime_versions = []
    for asset in assets:
        name = str(asset.get("name") or "")
        match = runtime_pattern.fullmatch(name)
        if not match:
            continue
        version = match.group("version")
        observed_runtime_versions.append(version)
        if compatible_version(version):
            runtime_matches.append((asset, match))

    checksum_assets = [asset for asset in assets if asset.get("name") == "SHA256SUMS"]
    tag_name = str(release.get("tag_name") or "<untagged>")
    if observed_runtime_versions or checksum_assets:
        diagnostics.append(
            f"{tag_name}: runtime versions={observed_runtime_versions or ['none']}, "
            f"matching={len(runtime_matches)}, SHA256SUMS={len(checksum_assets)}"
        )

    if len(runtime_matches) == 1 and len(checksum_assets) == 1:
        selected = (release, runtime_matches[0], checksum_assets[0])
        break

if selected is None:
    detail = "; ".join(diagnostics[:20]) or "no JBR runtime assets were found"
    raise SystemExit(
        "No published JBR release contains exactly one compatible Linux x64 "
        f"jbr_lb runtime for {expected_base_version}.x and one SHA256SUMS. "
        f"Observed: {detail}"
    )

release, (runtime_asset, runtime_match), checksum_asset = selected
asset_version = runtime_match.group("version")
asset_feature = asset_version.split(".", 1)[0]
if asset_feature != expected_feature:
    raise SystemExit(
        f"Selected JBR asset has Java feature {asset_feature}, "
        f"but PyCharm expects feature {expected_feature}"
    )

values = {
    "JBR_RELEASE_TAG": str(release.get("tag_name") or ""),
    "JBR_RELEASE_URL": str(release.get("html_url") or ""),
    "JBR_ASSET_NAME": str(runtime_asset.get("name") or ""),
    "JBR_ASSET_URL": str(runtime_asset.get("browser_download_url") or ""),
    "JBR_ASSET_VERSION": asset_version,
    "JBR_CHECKSUM_URL": str(checksum_asset.get("browser_download_url") or ""),
}
for key, value in values.items():
    if not value:
        raise SystemExit(f"GitHub release metadata is missing {key}")
    print(f"{key}={shlex.quote(value)}")
PY
# shellcheck disable=SC1090
source "${jbr_release_env}"

echo "Selected JBR release: ${JBR_RELEASE_TAG} (${JBR_ASSET_NAME})"

jbr_archive="${work_dir}/${JBR_ASSET_NAME}"
jbr_checksum_file="${work_dir}/SHA256SUMS"
curl_download_args=(
  --proto '=https'
  --proto-redir '=https'
  --tlsv1.2
  --fail
  --location
  --retry 5
  --retry-all-errors
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_download_args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
fi

curl "${curl_download_args[@]}" --output "${jbr_archive}" "${JBR_ASSET_URL}"
curl "${curl_download_args[@]}" --output "${jbr_checksum_file}" "${JBR_CHECKSUM_URL}"

expected_jbr_sha256="$(
  awk -v name="${JBR_ASSET_NAME}" '
    {
      candidate=$2
      sub(/^\*/, "", candidate)
      sub(/^\.\//, "", candidate)
      if (candidate == name) {
        print tolower($1)
        exit
      }
    }
  ' "${jbr_checksum_file}"
)"
[[ "${expected_jbr_sha256}" =~ ^[0-9a-f]{64}$ ]] \
  || fail "No valid SHA-256 entry for ${JBR_ASSET_NAME} was found in SHA256SUMS"
actual_jbr_sha256="$(sha256sum "${jbr_archive}" | awk '{print tolower($1)}')"
[[ "${actual_jbr_sha256}" == "${expected_jbr_sha256}" ]] \
  || fail "JBR SHA-256 verification failed for ${JBR_ASSET_NAME}"
echo "JBR SHA-256 verified: ${actual_jbr_sha256}"

tar --extract --gzip --file "${jbr_archive}" \
  --directory "${work_dir}/runtime-unpacked" --no-same-owner
mapfile -t runtime_java_candidates < <(
  find "${work_dir}/runtime-unpacked" \
    -mindepth 3 -maxdepth 3 -type f -path '*/bin/java' -print
)
if [[ ${#runtime_java_candidates[@]} -ne 1 ]]; then
  fail "Expected one JBR bin/java after extraction, found ${#runtime_java_candidates[@]}"
fi
jbr_root="$(dirname "$(dirname "${runtime_java_candidates[0]}")")"
expected_jbr_root_name="${JBR_ASSET_NAME%.tar.gz}"
[[ "$(basename "${jbr_root}")" == "${expected_jbr_root_name}" ]] \
  || fail "JBR archive root does not match asset name: $(basename "${jbr_root}") vs ${expected_jbr_root_name}"

rm -rf "${product_root}/jbr"
mv "${jbr_root}" "${product_root}/jbr"
java_executable="${product_root}/${JAVA_PATH}"
[[ -x "${java_executable}" ]] \
  || fail "Injected Java executable is missing or not executable: ${java_executable}"

runtime_settings="$("${java_executable}" -XshowSettings:properties -version 2>&1)"
jbr_runtime_version="$(
  awk -F' = ' '/^[[:space:]]*java\.runtime\.version = / { print $2; exit }' \
    <<< "${runtime_settings}"
)"
jbr_vendor="$(
  awk -F' = ' '/^[[:space:]]*java\.vendor = / { print $2; exit }' \
    <<< "${runtime_settings}"
)"
jbr_specification_version="$(
  awk -F' = ' '/^[[:space:]]*java\.specification\.version = / { print $2; exit }' \
    <<< "${runtime_settings}"
)"
[[ -n "${jbr_runtime_version}" ]] || fail "Unable to read the injected JBR runtime version"
[[ "${jbr_vendor}" == *JetBrains* ]] || fail "Unexpected injected Java vendor: ${jbr_vendor}"
[[ "${jbr_specification_version}" == "${runtime_feature}" ]] \
  || fail "Injected JBR Java feature ${jbr_specification_version} does not match expected feature ${runtime_feature}"

jbr_runtime_numeric="$(
  python3 - "${jbr_runtime_version}" <<'PY'
import re
import sys

match = re.match(r"^([0-9]+(?:\.[0-9]+)*)", sys.argv[1])
if match is None:
    raise SystemExit(f"Unable to parse java.runtime.version={sys.argv[1]!r}")
print(match.group(1))
PY
)"
[[ "${jbr_runtime_numeric}" == "${JBR_ASSET_VERSION}" ]] \
  || fail "Injected java.runtime.version ${jbr_runtime_version} does not match asset version ${JBR_ASSET_VERSION}"
if [[ "${jbr_runtime_numeric}" != "${runtime_base_version}" \
      && "${jbr_runtime_numeric}" != "${runtime_base_version}".* ]]; then
  fail "Injected JBR version ${jbr_runtime_numeric} is outside required runtime line ${runtime_base_version}.x"
fi
echo "Injected runtime: ${jbr_vendor} ${jbr_runtime_version} from ${JBR_RELEASE_TAG}"

# CentOS 7 ships glibc 2.17 and GCC 4.8-era libstdc++. Audit every directly
# bundled x86_64 ELF and ELF payload found inside JAR/ZIP archives.
audit_env="${work_dir}/abi-audit.env"
python3 - "${product_root}" > "${audit_env}" <<'PY'
import re
import shlex
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
limits = {
    "GLIBC": (2, 17),
    "GLIBCXX": (3, 4, 19),
    "CXXABI": (1, 3, 7),
}
patterns = {
    name: re.compile(rf"\bName: {name}_(\d+(?:\.\d+)+)\b")
    for name in limits
}
elf_count = 0
embedded_elf_count = 0
skipped_other_arch = 0
highest = {name: (0,) for name in limits}
failures = {name: [] for name in limits}


def parse_version(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def version_gt(candidate: tuple[int, ...], maximum: tuple[int, ...]) -> bool:
    width = max(len(candidate), len(maximum))
    return candidate + (0,) * (width - len(candidate)) > maximum + (0,) * (width - len(maximum))


def version_max(left: tuple[int, ...], right: tuple[int, ...]) -> tuple[int, ...]:
    return right if version_gt(right, left) else left


def display_version(value: tuple[int, ...]) -> str:
    return ".".join(str(part) for part in value)


def inspect_elf(path: Path, display_name: str) -> None:
    global elf_count, skipped_other_arch

    header = subprocess.run(
        ["readelf", "--file-header", "--wide", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if header.returncode != 0:
        raise SystemExit(
            f"readelf --file-header failed for {display_name}: {header.stderr.strip()}"
        )
    if "Advanced Micro Devices X86-64" not in header.stdout:
        skipped_other_arch += 1
        return

    elf_count += 1
    result = subprocess.run(
        ["readelf", "--version-info", "--wide", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"readelf --version-info failed for {display_name}: {result.stderr.strip()}"
        )

    in_needs_section = False
    required = {name: [] for name in limits}
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if line.startswith("Version needs section"):
            in_needs_section = True
            continue
        if line.startswith("Version ") and " section " in f" {line} ":
            in_needs_section = False
        if not in_needs_section:
            continue

        for name, pattern in patterns.items():
            required[name].extend(parse_version(match) for match in pattern.findall(line))

    for name, versions in required.items():
        if not versions:
            continue
        file_highest = versions[0]
        for version in versions[1:]:
            file_highest = version_max(file_highest, version)
        highest[name] = version_max(highest[name], file_highest)
        if version_gt(file_highest, limits[name]):
            failures[name].append((display_name, file_highest))


def inspect_archive(path: Path) -> None:
    global embedded_elf_count
    try:
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if member.is_dir():
                    continue
                with archive.open(member) as stream:
                    magic = stream.read(4)
                    if magic != b"\x7fELF":
                        continue
                    with tempfile.NamedTemporaryFile() as temporary:
                        temporary.write(magic)
                        temporary.write(stream.read())
                        temporary.flush()
                        embedded_elf_count += 1
                        inspect_elf(
                            Path(temporary.name),
                            f"{path.relative_to(root)}!/{member.filename}",
                        )
    except zipfile.BadZipFile as error:
        raise SystemExit(f"Invalid ZIP/JAR archive {path.relative_to(root)}: {error}") from error


for path in root.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    try:
        with path.open("rb") as stream:
            magic = stream.read(4)
    except OSError:
        continue

    if magic == b"\x7fELF":
        inspect_elf(path, str(path.relative_to(root)))
        continue

    if path.suffix.lower() in (".jar", ".zip"):
        inspect_archive(path)

if elf_count == 0:
    raise SystemExit("No Linux x86_64 ELF files were found in the distribution")

summary = ", ".join(
    f"{name}_{display_version(highest[name])}"
    for name in ("GLIBC", "GLIBCXX", "CXXABI")
)
print(
    f"Audited {elf_count} Linux x86_64 ELF files "
    f"({embedded_elf_count} embedded in JAR/ZIP archives); "
    f"highest required versions: {summary}",
    file=sys.stderr,
)
if skipped_other_arch:
    print(f"Skipped {skipped_other_arch} ELF files for other architectures", file=sys.stderr)

has_failures = False
for name in ("GLIBC", "GLIBCXX", "CXXABI"):
    entries = failures[name]
    if not entries:
        continue
    has_failures = True
    limit = display_version(limits[name])
    print(
        f"Files requiring {name} newer than the CentOS 7 system maximum ({limit}):",
        file=sys.stderr,
    )
    for display_name, version in entries[:100]:
        print(f"  {display_name}: {name}_{display_version(version)}", file=sys.stderr)
    if len(entries) > 100:
        print(f"  ... and {len(entries) - 100} more", file=sys.stderr)

if has_failures:
    raise SystemExit(1)

values = {
    "ABI_ELF_COUNT": str(elf_count),
    "ABI_EMBEDDED_ELF_COUNT": str(embedded_elf_count),
    "ABI_HIGHEST_GLIBC": display_version(highest["GLIBC"]),
    "ABI_HIGHEST_GLIBCXX": display_version(highest["GLIBCXX"]),
    "ABI_HIGHEST_CXXABI": display_version(highest["CXXABI"]),
}
for key, value in values.items():
    print(f"{key}={shlex.quote(value)}")
PY
# shellcheck disable=SC1090
source "${audit_env}"

centos_image="quay.io/centos/centos:7"
docker pull "${centos_image}"
docker run --rm \
  --platform linux/amd64 \
  --volume "${product_root}:/opt/pycharm:ro" \
  --env "PYCHARM_LAUNCHER=/opt/pycharm/${LAUNCHER_PATH}" \
  --env "PYCHARM_JAVA=/opt/pycharm/${JAVA_PATH}" \
  --env "HOME=/tmp/pycharm-home" \
  "${centos_image}" \
  /bin/bash -lc '
    set -euo pipefail
    mkdir -p "${HOME}"
    libc_version="$(getconf GNU_LIBC_VERSION)"
    if [[ "${libc_version}" != "glibc 2.17" ]]; then
      echo "Unexpected container libc: ${libc_version}" >&2
      exit 1
    fi
    "${PYCHARM_JAVA}" -version
    timeout 120 "${PYCHARM_LAUNCHER}" --version
  '

release_artifact="${artifacts_dir}/pycharm-centos7-${RELEASE_TAG}-linux-x64.tar.gz"
release_checksum="${release_artifact}.sha256"
rm -f "${release_artifact}" "${release_checksum}"

# Original checksums, the SBOM, and the installation-integrity manifest describe
# the unmodified upstream package and are invalid after runtime replacement.
# The sibling product-info.json is used only to cross-check official metadata; the
# same product-info.json remains inside the final tar because its paths are unchanged.
rm -f \
  "${original_artifact}" \
  "${original_artifact}".sha256* \
  "${original_artifact}".sha512* \
  "${original_artifact}".spdx.json* \
  "${product_info_sibling}" \
  "${artifacts_dir}/PC-${expected_build_number}.tar.gz.manifest"

tar \
  --create \
  --gzip \
  --file "${release_artifact}" \
  --directory "${work_dir}/extracted" \
  "${PRODUCT_ROOT_RELATIVE}"

tar -tzf "${release_artifact}" | grep -Fqx "${PRODUCT_ROOT_RELATIVE}/product-info.json" \
  || fail "Repacked artifact is missing product-info.json"
tar -tzf "${release_artifact}" | grep -Fqx "${PRODUCT_ROOT_RELATIVE}/${JAVA_PATH}" \
  || fail "Repacked artifact is missing the injected Java executable"
tar -tzf "${release_artifact}" | grep -Fqx "${PRODUCT_ROOT_RELATIVE}/${LAUNCHER_PATH}" \
  || fail "Repacked artifact is missing the PyCharm launcher"

(
  cd "$(dirname "${release_artifact}")"
  sha256sum --binary "$(basename "${release_artifact}")" > "$(basename "${release_checksum}")"
)

notes_file="${work_dir}/release-notes.md"
cat > "${notes_file}" <<EOF
# PyCharm Open Source for CentOS 7

- Product version: \`${PRODUCT_VERSION}${VERSION_SUFFIX:+ ${VERSION_SUFFIX}}\`
- Build number: \`${FULL_BUILD_NUMBER}\`
- Source snapshot: \`${source_snapshot}\`
- Source commit: \`${GITHUB_SHA}\`
- Target: Linux x86_64, CentOS 7 / glibc 2.17
- Upstream runtime requirement: \`${runtime_build}\`
- Compatible custom JBR line: \`${runtime_base_version}.x\`
- Embedded runtime: \`${jbr_vendor} ${jbr_runtime_version}\`
- JBR release: \`${jbr_release_repository}@${JBR_RELEASE_TAG}\`
- JBR asset: \`${JBR_ASSET_NAME}\`
- JBR SHA-256: \`${actual_jbr_sha256}\`
- ABI audit: \`${ABI_ELF_COUNT}\` Linux x86_64 ELF files, including \`${ABI_EMBEDDED_ELF_COUNT}\` embedded native files; highest required GLIBC \`${ABI_HIGHEST_GLIBC}\`, GLIBCXX \`${ABI_HIGHEST_GLIBCXX}\`, CXXABI \`${ABI_HIGHEST_CXXABI}\`

This is an unofficial PyCharm compatibility build from the synchronized JetBrains upstream source. The official PyCharm Linux package layout and product-info metadata are validated before modification. Its bundled runtime is replaced with the newest published non-draft CentOS 7 JBR release from ${jbr_release_repository} that stays on the source tree's required runtime version line. The workflow verifies SHA256SUMS, validates the injected runtime identity/version, audits native binaries against CentOS 7 GLIBC/GLIBCXX/CXXABI limits, and runs both Java and the PyCharm launcher inside a CentOS 7 container before publishing.

The original upstream checksums, SBOM, and installation-integrity manifest are not published because runtime replacement invalidates them. The upstream product-info sibling is used only to cross-check the internal metadata; the unchanged product-info.json remains inside the final tar.
EOF

{
  echo "tag=${RELEASE_TAG}"
  echo "artifact=${release_artifact}"
  echo "checksum=${release_checksum}"
  echo "notes=${notes_file}"
  echo "prerelease=${IS_PRERELEASE}"
  echo "product_version=${PRODUCT_VERSION}"
  echo "full_build_number=${FULL_BUILD_NUMBER}"
  echo "required_runtime_build=${runtime_build}"
  echo "runtime_version=${jbr_runtime_version}"
  echo "jbr_release_tag=${JBR_RELEASE_TAG}"
  echo "highest_glibc=${ABI_HIGHEST_GLIBC}"
  echo "highest_glibcxx=${ABI_HIGHEST_GLIBCXX}"
  echo "highest_cxxabi=${ABI_HIGHEST_CXXABI}"
} >> "${output_file}"
