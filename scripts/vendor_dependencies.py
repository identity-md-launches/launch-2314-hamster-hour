#!/usr/bin/env python3
"""Restore the pinned, unmodified Solidity sources used by this project.

Optional maintenance tool; builds and tests use the checked-in files and never
run this script. No Git repositories, submodules, or package managers are used.
"""

import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = [
    (
        "v4-core",
        "Uniswap/v4-core",
        "46c6834698c48bc4a463a86d8420f4eb1d7f3b75",
        lambda p: (p.startswith("src/") and not p.startswith("src/test/"))
        or p in ("licenses/BUSL_LICENSE", "licenses/MIT_LICENSE"),
    ),
    (
        "forge-std",
        "foundry-rs/forge-std",
        "77041d2ce690e692d6e03cc812b57d1ddaa4d505",
        lambda p: p.startswith("src/") or p in ("LICENSE-APACHE", "LICENSE-MIT"),
    ),
    (
        "openzeppelin-contracts",
        "OpenZeppelin/openzeppelin-contracts",
        "acd4ff74de833399287ed6b31b4debf6b2b35527",
        lambda p: p in (
            "LICENSE",
            "contracts/token/ERC20/ERC20.sol",
            "contracts/token/ERC20/IERC20.sol",
            "contracts/token/ERC20/extensions/IERC20Metadata.sol",
            "contracts/interfaces/draft-IERC6093.sol",
            "contracts/utils/Context.sol",
        ),
    ),
    (
        "solmate",
        "transmissions11/solmate",
        "4b47a19038b798b4a33d9749d25e570443520647",
        lambda p: p in ("LICENSE", "src/auth/Owned.sol"),
    ),
]


def main():
    provenance = []
    for name, repository, revision, include in PACKAGES:
        url = f"https://codeload.github.com/{repository}/tar.gz/{revision}"
        request = urllib.request.Request(url, headers={"User-Agent": "HamsterHour-source-vendor"})
        with urllib.request.urlopen(request, timeout=60) as response:
            archive = response.read()
        files = {}
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as package:
            for member in package:
                path = PurePosixPath(member.name)
                relative = PurePosixPath(*path.parts[1:])
                if not member.isfile() or not include(str(relative)):
                    continue
                if relative.is_absolute() or any(
                    part in ("..", ".git", ".github", "node_modules") or part.startswith(".env")
                    for part in relative.parts
                ):
                    raise ValueError(f"Unsafe package path: {relative}")
                content = package.extractfile(member).read()
                destination = ROOT / "lib" / name / str(relative)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(content)
                files[str(relative)] = hashlib.sha256(content).hexdigest()
        provenance.append(
            {
                "name": name,
                "repository": f"https://github.com/{repository}",
                "revision": revision,
                "source": url,
                "archive_sha256": hashlib.sha256(archive).hexdigest(),
                "files_sha256": files,
            }
        )
        print(f"{name}: {len(files)} source/license files at {revision}")
    (ROOT / "lib" / "dependencies.json").write_text(json.dumps(provenance, indent=2) + "\n")


if __name__ == "__main__":
    main()
