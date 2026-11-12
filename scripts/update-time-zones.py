#!/usr/bin/env python3
"""Regenerate the display time zone catalog from an official IANA tzdata archive."""

import argparse
import re
import tarfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="Downloaded tzdataYYYYx.tar.gz")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "identity/time_zones.mbt")
    args = parser.parse_args()
    names = {"UTC"}
    with tarfile.open(args.archive) as archive:
        version = archive.extractfile("version").read().decode().strip()
        if not re.fullmatch(r"\d{4}[a-z]+", version):
            raise ValueError("Unexpected tzdata version")
        for source in ("africa", "antarctica", "asia", "australasia", "europe", "northamerica", "southamerica", "etcetera", "backward"):
            for line in archive.extractfile(source).read().decode().splitlines():
                fields = line.split("#", 1)[0].split()
                if fields and fields[0] in ("Zone", "Link"):
                    names.add(fields[1] if fields[0] == "Zone" else fields[2])
    names.discard("Factory")  # Not a display time zone supported by Intl.
    if len(names) < 400 or any(not re.fullmatch(r"[A-Za-z0-9_+/\-]+", name) for name in names):
        raise ValueError("Unexpected time zone catalog")
    output = (
        f"// IANA tzdb {version} Zone and Link identifiers (public domain).\n"
        f"// Source: https://data.iana.org/time-zones/releases/tzdata{version}.tar.gz\n"
        "// Display rules come from the browser; this catalog validates account preferences.\n\n"
        "///|\npub fn display_time_zones() -> Array[String] {\n  [\n"
        + "".join(f'    "{name}",\n' for name in sorted(names))
        + "  ]\n}\n\n///|\npub fn valid_display_time_zone(time_zone : String?) -> Bool {\n"
        "  match time_zone {\n    None => true\n    Some(zone) => display_time_zones().contains(zone)\n  }\n}\n"
    )
    args.output.write_text(output, encoding="utf-8")


if __name__ == "__main__":
    main()
