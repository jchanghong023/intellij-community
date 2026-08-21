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
work_dir="${runner_temp}/idea-centos7-${run_id}-${run_attempt}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command is unavailable: $1"
}

for command_name in awk curl docker find python3 readelf sha256sum tar; do
  require_command "${command_name}"
done

original_artifact="${artifacts_dir}/ideaIC-${expected_build_number}.tar.gz"
if [[ ! -f "${original_artifact}" ]]; then
  echo "Expected Linux artifact was not produced: ${original_artifact}" >&2
  find "${artifacts_dir}" -maxdepth 1 -type f -printf '%f\n' | sort >&2 || true
  exit 1
fi

rm -rf "${work_dir}"
mkdir -p "${work_dir}/extracted" "${work_dir}/runtime-unpacked"

product_info_relative="$({ tar -tzf "${original_artifact}" || true; } | awk '/(^|\/)product-info\.json$/ { print; exit }')"
[[ -n "${product_info_relative}" ]] || fail "product-info.json is missing from ${original_artifact}"

product_info_file="${work_dir}/product-info.json"
tar -xOf "${original_artifact}" "${product_info_relative}" > "${product_info_file}"

metadata_env="${work_dir}/metadata.env"
python3 - "${product_info_file}" "${expected_build_number}" "${product_info_relative}" > "${metadata_env}" <<'PY'
import json
import re
import shlex
import sys
from pathlib import PurePosixPath

product_info_path, expected_build_number, product_info_relative = sys.argv[1:]
with open(product_info_path, encoding="utf-8") as stream:
    product = json.load(stream)

version = str(product["version"]).strip()
version_suffix = str(product.get("versionSuffix") or "").strip()
product_code = str(product["productCode"]).strip()
full_build_number = str(product["buildNumber"]).strip()
expected_full_build_number = f"{product_code}-{expected_build_number}"
if full_build_number != expected_full_build_number:
    raise SystemExit(
        f"product-info.json contains buildNumber={full_build_number!r}; "
        f"expected {expected_full_build_number!r}"
    )

product_info_path_in_archive = PurePosixPath(product_info_relative)
if product_info_path_in_archive.is_absolute() or ".." in product_info_path_in_archive.parts:
    raise SystemExit(f"Unsafe product-info.json path: {product_info_relative!r}")
product_root = product_info_path_in_archive.parent
if str(product_root) in ("", "."):
    raise SystemExit("The product archive must contain a top-level product directory")

linux_launches = [
    item
    for item in product.get("launch", [])
    if item.get("os") == "linux" and item.get("arch") in (None, "x64")
]
if not linux_launches:
    raise SystemExit("No Linux x64 launch entry was found in product-info.json")

preferred = [
    item
    for item in linux_launches
    if str(item.get("launcherPath") or "").endswith("/idea")
    or str(item.get("launcherPath") or "") == "bin/idea"
]
launch = preferred[0] if preferred else linux_launches[0]
launcher_path = str(launch["launcherPath"])
java_path = str(launch.get("javaExecutablePath") or "jbr/bin/java")

for label, relative_path in (("launcherPath", launcher_path), ("javaExecutablePath", java_path)):
    path = PurePosixPath(relative_path)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"Unsafe {label}: {relative_path!r}")


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
    "IS_PRERELEASE": "true" if version_suffix else "false",
}
for key, value in values.items():
    print(f"{key}={shlex.quote(value)}")
PY
# Values are shell-escaped by the Python code above.
# shellcheck disable=SC1090
source "${metadata_env}"

[[ "${JAVA_PATH}" == jbr/* ]] || fail "Expected the bundled Java path under jbr/, found: ${JAVA_PATH}"

tar --extract --gzip --file "${original_artifact}" --directory "${work_dir}/extracted" --no-same-owner
product_root="${work_dir}/extracted/${PRODUCT_ROOT_RELATIVE}"
[[ -d "${product_root}" ]] || fail "Unable to determine extracted product root: ${product_root}"

launcher_executable="${product_root}/${LAUNCHER_PATH}"
[[ -x "${launcher_executable}" ]] || fail "IDE launcher is missing or not executable: ${launcher_executable}"

runtime_build="$({ awk -F= '$1 == "runtimeBuild" { print $2; exit }' build/dependencies/dependencies.properties || true; })"
if [[ ! "${runtime_build}" =~ ^([0-9]+)(\..*)?$ ]]; then
  fail "Unable to derive the upstream runtime feature version from runtimeBuild=${runtime_build}"
fi
runtime_feature="${BASH_REMATCH[1]}"

temurin_api_url="https://api.adoptium.net/v3/binary/latest/${runtime_feature}/ga/linux/x64/jdk/hotspot/normal/eclipse"
echo "Resolving Eclipse Temurin JDK ${runtime_feature} from ${temurin_api_url}"
temurin_download_url="$(
  curl \
    --proto '=https' \
    --tlsv1.2 \
    --silent \
    --show-error \
    --fail \
    --output /dev/null \
    --write-out '%{redirect_url}' \
    "${temurin_api_url}"
)"
[[ "${temurin_download_url}" == https://* ]] || fail "Adoptium API did not return an HTTPS download URL"

temurin_archive="${work_dir}/temurin-jdk.tar.gz"
temurin_checksum_file="${work_dir}/temurin-jdk.sha256.txt"
curl \
  --proto '=https' \
  --proto-redir '=https' \
  --tlsv1.2 \
  --fail \
  --location \
  --retry 5 \
  --retry-all-errors \
  --output "${temurin_archive}" \
  "${temurin_download_url}"
curl \
  --proto '=https' \
  --proto-redir '=https' \
  --tlsv1.2 \
  --fail \
  --location \
  --retry 5 \
  --retry-all-errors \
  --output "${temurin_checksum_file}" \
  "${temurin_download_url}.sha256.txt"

expected_temurin_sha256="$(python3 - "${temurin_checksum_file}" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict")
match = re.search(r"(?i)(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])", text)
if match is None:
    raise SystemExit("No SHA-256 checksum was found in the Temurin checksum file")
print(match.group(0).lower())
PY
)"
actual_temurin_sha256="$(sha256sum "${temurin_archive}" | awk '{print tolower($1)}')"
[[ "${actual_temurin_sha256}" == "${expected_temurin_sha256}" ]] || fail "Temurin SHA-256 verification failed"
echo "Eclipse Temurin SHA-256 verified: ${actual_temurin_sha256}"

tar --extract --gzip --file "${temurin_archive}" --directory "${work_dir}/runtime-unpacked" --no-same-owner
mapfile -t runtime_java_candidates < <(
  find "${work_dir}/runtime-unpacked" -mindepth 3 -maxdepth 3 -type f -path '*/bin/java' -print
)
if [[ ${#runtime_java_candidates[@]} -ne 1 ]]; then
  fail "Expected one Temurin bin/java after extraction, found ${#runtime_java_candidates[@]}"
fi
temurin_root="$(dirname "$(dirname "${runtime_java_candidates[0]}")")"

rm -rf "${product_root}/jbr"
mv "${temurin_root}" "${product_root}/jbr"
java_executable="${product_root}/${JAVA_PATH}"
[[ -x "${java_executable}" ]] || fail "Injected Java executable is missing or not executable: ${java_executable}"

runtime_settings="$("${java_executable}" -XshowSettings:properties -version 2>&1)"
temurin_runtime_version="$(awk -F' = ' '/^[[:space:]]*java\.runtime\.version = / { print $2; exit }' <<< "${runtime_settings}")"
temurin_vendor="$(awk -F' = ' '/^[[:space:]]*java\.vendor = / { print $2; exit }' <<< "${runtime_settings}")"
[[ -n "${temurin_runtime_version}" ]] || fail "Unable to read the injected Java runtime version"
[[ "${temurin_vendor}" == *Adoptium* ]] || fail "Unexpected injected Java vendor: ${temurin_vendor}"
echo "Injected runtime: ${temurin_vendor} ${temurin_runtime_version}"

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
limit = (2, 17)
glibc_pattern = re.compile(r"\bName: GLIBC_(\d+)\.(\d+)(?:\.\d+)?\b")
elf_count = 0
embedded_elf_count = 0
skipped_other_arch = 0
highest = (0, 0)
failures: list[tuple[str, tuple[int, int]]] = []


def inspect_elf(path: Path, display_name: str) -> None:
    global elf_count, highest, skipped_other_arch

    header = subprocess.run(
        ["readelf", "--file-header", "--wide", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if header.returncode != 0:
        raise SystemExit(f"readelf --file-header failed for {display_name}: {header.stderr.strip()}")
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
        raise SystemExit(f"readelf --version-info failed for {display_name}: {result.stderr.strip()}")

    in_needs_section = False
    required: list[tuple[int, int]] = []
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if line.startswith("Version needs section"):
            in_needs_section = True
            continue
        if line.startswith("Version ") and " section " in f" {line} ":
            in_needs_section = False
        if in_needs_section:
            required.extend(tuple(map(int, match)) for match in glibc_pattern.findall(line))

    if not required:
        return
    file_highest = max(required)
    highest = max(highest, file_highest)
    if file_highest > limit:
        failures.append((display_name, file_highest))


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

    if path.suffix.lower() != ".jar":
        continue
    try:
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if member.is_dir() or not member.filename.lower().endswith(".so"):
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
        raise SystemExit(f"Invalid JAR archive {path.relative_to(root)}: {error}") from error

if elf_count == 0:
    raise SystemExit("No Linux x86_64 ELF files were found in the distribution")

print(
    f"Audited {elf_count} Linux x86_64 ELF files "
    f"({embedded_elf_count} embedded in JARs); "
    f"highest required glibc is {highest[0]}.{highest[1]}",
    file=sys.stderr,
)
if skipped_other_arch:
    print(f"Skipped {skipped_other_arch} ELF files for other architectures", file=sys.stderr)

if failures:
    print("Files requiring a glibc newer than CentOS 7 (2.17):", file=sys.stderr)
    for display_name, version in failures[:100]:
        print(f"  {display_name}: GLIBC_{version[0]}.{version[1]}", file=sys.stderr)
    if len(failures) > 100:
        print(f"  ... and {len(failures) - 100} more", file=sys.stderr)
    raise SystemExit(1)

values = {
    "ABI_ELF_COUNT": str(elf_count),
    "ABI_EMBEDDED_ELF_COUNT": str(embedded_elf_count),
    "ABI_HIGHEST_GLIBC": f"{highest[0]}.{highest[1]}",
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
  --volume "${product_root}:/opt/idea:ro" \
  --env "IDEA_LAUNCHER=/opt/idea/${LAUNCHER_PATH}" \
  --env "IDEA_JAVA=/opt/idea/${JAVA_PATH}" \
  --env "HOME=/tmp/idea-home" \
  "${centos_image}" \
  /bin/bash -lc '
    set -euo pipefail
    mkdir -p "${HOME}"
    libc_version="$(getconf GNU_LIBC_VERSION)"
    if [[ "${libc_version}" != "glibc 2.17" ]]; then
      echo "Unexpected container libc: ${libc_version}" >&2
      exit 1
    fi
    "${IDEA_JAVA}" -version
    timeout 120 "${IDEA_LAUNCHER}" --version
  '

release_artifact="${artifacts_dir}/idea-centos7-${RELEASE_TAG}-linux-x64.tar.gz"
release_checksum="${release_artifact}.sha256"
rm -f "${release_artifact}" "${release_checksum}"

# The upstream SBOM and checksums describe the original JetBrains Runtime and are
# intentionally removed because this compatibility package has a replaced runtime.
rm -f \
  "${original_artifact}" \
  "${original_artifact}.sha256" \
  "${original_artifact}.spdx.json" \
  "${original_artifact}.spdx.json.sha256"

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

(
  cd "$(dirname "${release_artifact}")"
  sha256sum --binary "$(basename "${release_artifact}")" > "$(basename "${release_checksum}")"
)

notes_file="${work_dir}/release-notes.md"
cat > "${notes_file}" <<EOF
# IntelliJ IDEA Open Source for CentOS 7

- Product version: \`${PRODUCT_VERSION}${VERSION_SUFFIX:+ ${VERSION_SUFFIX}}\`
- Build number: \`${FULL_BUILD_NUMBER}\`
- Source snapshot: \`${source_snapshot}\`
- Source commit: \`${GITHUB_SHA}\`
- Target: Linux x86_64, CentOS 7 / glibc 2.17
- Embedded runtime: \`${temurin_vendor} ${temurin_runtime_version}\`
- ABI audit: \`${ABI_ELF_COUNT}\` Linux x86_64 ELF files, including \`${ABI_EMBEDDED_ELF_COUNT}\` embedded native libraries; highest required glibc \`${ABI_HIGHEST_GLIBC}\`

This is an unofficial compatibility build from the synchronized JetBrains upstream source. The upstream JetBrains Runtime is replaced with an Eclipse Temurin JDK whose Java feature version matches the runtime feature used by the source tree. The workflow verifies the Temurin SHA-256 checksum, audits native binaries for glibc 2.17 compatibility, and runs both Java and the IDE launcher inside a CentOS 7 container before publishing.

Because this package does not use JetBrains Runtime, JBR-specific fixes and JCEF-based embedded browser features may be unavailable. The upstream SBOM is not published because replacing the runtime makes that SBOM inaccurate.
EOF

{
  echo "tag=${RELEASE_TAG}"
  echo "artifact=${release_artifact}"
  echo "checksum=${release_checksum}"
  echo "notes=${notes_file}"
  echo "prerelease=${IS_PRERELEASE}"
  echo "product_version=${PRODUCT_VERSION}"
  echo "full_build_number=${FULL_BUILD_NUMBER}"
  echo "runtime_version=${temurin_runtime_version}"
  echo "highest_glibc=${ABI_HIGHEST_GLIBC}"
} >> "${output_file}"
