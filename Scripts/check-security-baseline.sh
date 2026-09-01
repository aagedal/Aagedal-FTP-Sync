#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_dir")
resolved="$repository_root/Aagedal FTP Sync.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
signature_source="$repository_root/Vendor/swift-nio-ssh/Sources/NIOSSH/Keys And Signatures/NIOSSHSignature.swift"

crypto_version=$(awk '
    /"identity" : "swift-crypto"/ { found = 1 }
    found && /"version"/ { gsub(/[",]/, "", $3); print $3; exit }
' "$resolved")

if ! awk -v version="$crypto_version" 'BEGIN {
    count = split(version, part, ".")
    secure = count == 3 && (part[1] > 4 || (part[1] == 4 && (part[2] > 5 || (part[2] == 5 && part[3] >= 1))))
    exit secure ? 0 : 1
}'; then
    echo "security baseline failed: Swift Crypto must resolve to 4.5.1 or newer (found ${crypto_version:-none})" >&2
    exit 1
fi

if ! rg --fixed-strings \
    'guard rByteView.count <= pointSize, sByteView.count <= pointSize else {' \
    "$signature_source" >/dev/null; then
    echo "security baseline failed: the CVE-2026-43798 bounds check is missing" >&2
    exit 1
fi

if rg 'github\.com/Wellz26/swift-nio-ssh' \
    "$repository_root/project.yml" \
    "$repository_root/Vendor/Citadel/Package.swift" \
    "$resolved" >/dev/null; then
    echo "security baseline failed: the build references the unpatched remote SSH fork" >&2
    exit 1
fi

if ! rg --fixed-strings 'PinnedHostKeyValidator' \
    "$repository_root/AagedalFTPSync/Sync/SFTP/SFTPTransport.swift" >/dev/null; then
    echo "security baseline failed: SFTP host-key pinning is not enabled" >&2
    exit 1
fi

echo "Security dependency baseline verified."
