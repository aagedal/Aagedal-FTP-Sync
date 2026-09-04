#!/bin/sh
set -eu

usage() {
    echo "Usage: Scripts/check-release-identity.sh [expected-version [expected-build]]" >&2
}

if [ "$#" -gt 2 ]; then
    usage
    exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_dir")
project_spec="$repository_root/project.yml"
xcode_project="$repository_root/Aagedal FTP Sync.xcodeproj/project.pbxproj"
info_plist="$repository_root/AagedalFTPSync/Resources/Info.plist"
changelog="$repository_root/CHANGELOG.md"
security_policy="$repository_root/SECURITY.md"

fail() {
    echo "release identity check failed: $1" >&2
    exit 1
}

project_setting() {
    setting_name=$1
    awk -v setting="$setting_name:" '$1 == setting { print $2 }' "$project_spec"
}

require_single_value() {
    setting_name=$1
    setting_values=$2
    setting_count=$(printf '%s\n' "$setting_values" | awk 'NF { count++ } END { print count + 0 }')
    [ "$setting_count" -eq 1 ] || fail "project.yml must define $setting_name exactly once"
}

marketing_version=$(project_setting MARKETING_VERSION)
build_number=$(project_setting CURRENT_PROJECT_VERSION)
require_single_value MARKETING_VERSION "$marketing_version"
require_single_value CURRENT_PROJECT_VERSION "$build_number"

if ! printf '%s\n' "$marketing_version" | awk -F. '
    NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { valid = 1 }
    END { exit valid ? 0 : 1 }
'; then
    fail "MARKETING_VERSION must be a three-part numeric version (found $marketing_version)"
fi

if ! printf '%s\n' "$build_number" | awk '
    /^[0-9]+$/ && ($0 + 0) > 0 { valid = 1 }
    END { exit valid ? 0 : 1 }
'; then
    fail "CURRENT_PROJECT_VERSION must be a positive integer (found $build_number)"
fi

if [ "$#" -ge 1 ] && [ "$marketing_version" != "$1" ]; then
    fail "expected version $1 but project.yml declares $marketing_version"
fi

if [ "$#" -eq 2 ] && [ "$build_number" != "$2" ]; then
    fail "expected build $2 but project.yml declares $build_number"
fi

check_generated_setting() {
    setting_name=$1
    expected_value=$2
    setting_values=$(awk -v setting="$setting_name" '
        $1 == setting && $2 == "=" {
            value = $3
            sub(/;$/, "", value)
            print value
        }
    ' "$xcode_project")
    setting_count=$(printf '%s\n' "$setting_values" | awk 'NF { count++ } END { print count + 0 }')

    [ "$setting_count" -gt 0 ] || fail "$xcode_project does not define $setting_name"
    if ! printf '%s\n' "$setting_values" | awk -v expected="$expected_value" '
        NF && $0 != expected { mismatched = 1 }
        END { exit mismatched ? 1 : 0 }
    '; then
        fail "generated Xcode project has a $setting_name value that differs from $expected_value; run xcodegen generate"
    fi
}

check_generated_setting MARKETING_VERSION "$marketing_version"
check_generated_setting CURRENT_PROJECT_VERSION "$build_number"

plist_value() {
    plist_key=$1
    awk -v key="<key>$plist_key</key>" '
        index($0, key) {
            if (getline <= 0) {
                exit
            }
            value = $0
            sub(/^[[:space:]]*<string>/, "", value)
            sub(/<\/string>[[:space:]]*$/, "", value)
            print value
            exit
        }
    ' "$info_plist"
}

short_version_value=$(plist_value CFBundleShortVersionString)
if [ "$short_version_value" != '$(MARKETING_VERSION)' ]; then
    fail "Info.plist must source CFBundleShortVersionString from MARKETING_VERSION"
fi

bundle_version_value=$(plist_value CFBundleVersion)
if [ "$bundle_version_value" != '$(CURRENT_PROJECT_VERSION)' ]; then
    fail "Info.plist must source CFBundleVersion from CURRENT_PROJECT_VERSION"
fi

release_heading_count=$(awk -v version="$marketing_version" '
    index($0, "## " version " — ") == 1 {
        release_date = substr($0, length("## " version " — ") + 1)
        if (release_date ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
            count++
        }
    }
    END { print count + 0 }
' "$changelog")
[ "$release_heading_count" -eq 1 ] || fail "CHANGELOG.md must contain exactly one '## $marketing_version — YYYY-MM-DD' release heading"

latest_changelog_version=$(awk '
    /^## [0-9]+\.[0-9]+\.[0-9]+ / {
        print $2
        exit
    }
' "$changelog")
[ "$latest_changelog_version" = "$marketing_version" ] || fail "latest changelog release is ${latest_changelog_version:-missing}, not $marketing_version"

release_line=$(printf '%s\n' "$marketing_version" | awk -F. '{ print $1 "." $2 }')
supported_release_policy=$(awk '
    /^## Supported release$/ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { print }
' "$security_policy")

if ! printf '%s\n' "$supported_release_policy" | grep -F "the $release_line release line" >/dev/null; then
    fail "SECURITY.md must identify $release_line as the supported release line"
fi

if ! printf '%s\n' "$supported_release_policy" | grep -F "latest available $release_line.x version" >/dev/null; then
    fail "SECURITY.md must direct users to the latest available $release_line.x version"
fi

echo "Release identity verified for $marketing_version (build $build_number)."
