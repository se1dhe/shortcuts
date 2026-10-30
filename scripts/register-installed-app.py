#!/usr/bin/env python3
"""Keep only the installed КАДР & СЕНС in LaunchServices (no global reset)."""
import argparse
import pathlib
import plistlib
import re
import subprocess

LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
BUNDLE_ID = "app.shortcast.Shortcast"
ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_NAME = "КАДР & СЕНС.app"
PRODUCT_CONFIGURATIONS = ("Debug", "Release")


def bundle_id(path):
    try:
        with (path / "Contents/Info.plist").open("rb") as stream:
            return plistlib.load(stream).get("CFBundleIdentifier")
    except (OSError, plistlib.InvalidFileException):
        return None


def registered_paths(dump):
    for record in dump.split("--------------------------------------------------------------------------------"):
        match = re.search(r"^path:\s+(.*?) \(0x[0-9a-f]+\)\s*$", record, re.M)
        if not match:
            continue
        path = pathlib.Path(match[1])
        identified = re.search(r"^identifier:\s+app\.shortcast\.Shortcast\s*$", record, re.M)
        # Older interrupted builds can be registered without an Info.plist or ID.
        local_product = path.name in ("КАДР & СЕНС.app", "Short Generator.app", "Shortcast.app") and any(
            parent in path.parents for parent in (ROOT / "build", ROOT / ".build", ROOT / ".derivedData")
        )
        if identified or local_product:
            yield path


def generated_products(installed):
    """Find duplicate app bundles Xcode leaves searchable in Build/Products."""
    derived_data = pathlib.Path.home().glob(
        "Library/Developer/Xcode/DerivedData/Shortcast-*"
    )
    roots = [
        ROOT / ".build" / "Build" / "Products",
        ROOT / "build" / "Build" / "Products",
        ROOT / ".derivedData" / "Build" / "Products",
    ]
    for derived in derived_data:
        roots.extend((derived / "Build" / "Products", *derived.glob("*/Build/Products")))
    products = set()
    for root in roots:
        for configuration in PRODUCT_CONFIGURATIONS:
            for app_name in (APP_NAME, "Short Generator.app"):
                candidate = root / configuration / app_name
                # A copied product can be interrupted before Xcode writes its
                # Info.plist. Its project-specific Build/Products location and app
                # name still identify it as a stale generated Shortcast bundle.
                if candidate != installed and bundle_id(candidate) in (None, BUNDLE_ID):
                    if not candidate.is_dir():
                        continue
                    products.add(candidate)
    return products


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Report registrations without changing them")
    parser.add_argument("--installed", type=pathlib.Path)
    args = parser.parse_args()
    installed = args.installed
    if installed is None:
        installed = next((p for p in (
            pathlib.Path("/Applications/КАДР & СЕНС.app"),
            pathlib.Path.home() / "Applications/КАДР & СЕНС.app",
        ) if bundle_id(p) == BUNDLE_ID), None)
    if installed is None or bundle_id(installed) != BUNDLE_ID:
        parser.error("A valid installed КАДР & СЕНС is required before cleaning registrations")
    installed = installed.resolve()
    dump = subprocess.check_output([LSREGISTER, "-dump"], text=True)
    paths = set(registered_paths(dump))
    installed_registered = any(p.resolve() == installed for p in paths)
    stale = sorted(p for p in paths if p.resolve() != installed)
    products = sorted(generated_products(installed))
    for path in stale:
        print(f"{'Duplicate' if args.check else 'Unregistering'}: {path}", flush=True)
        if not args.check:
            subprocess.run([LSREGISTER, "-u", str(path)], check=True)
    for path in products:
        print(f"{'Build product' if args.check else 'Hiding Xcode build product'}: {path}", flush=True)
        if not args.check:
            subprocess.run(["/usr/bin/chflags", "hidden", str(path)], check=True)
    if not args.check:
        subprocess.run([LSREGISTER, "-f", "-trusted", str(installed)], check=True)
    elif not installed_registered:
        print(f"Missing registration: {installed}")
        return 1
    print(f"Installed: {installed}")
    return 1 if args.check and stale else 0


if __name__ == "__main__":
    raise SystemExit(main())
