#!/usr/bin/env python3
"""Select one imported SmartDNS provider and preserve its pinned sources."""
from pathlib import Path
import re
import shutil
import sys

BACKENDS = (Path("feeds/passwall_packages/smartdns"),
            Path("package/custom_packages/openwrt-smartdns"),
            Path("feeds/packages/net/smartdns"))
LUCIS = (Path("package/custom_packages/luci-app-smartdns"),
         Path("feeds/luci/applications/luci-app-smartdns"))

def assignment(text, name):
    values = re.findall(r"(?m)^[ \t]*" + re.escape(name) + r":=[ \t]*(\S+)[ \t]*$", text)
    if len(values) != 1:
        raise SystemExit("Missing or ambiguous SmartDNS source field: " + name)
    return values[0]

def select():
    # Stock SmartDNS may lack the dashboard. Only accept a complete imported provider.
    backend = next((p for p in BACKENDS[:2] if (p / "Makefile").is_file()), None)
    luci = next((p for p in LUCIS if (p / "Makefile").is_file()), None)
    if backend is None or luci is None:
        raise SystemExit("Missing imported SmartDNS backend or LuCI package definition")
    text = (backend / "Makefile").read_text(encoding="utf-8")
    for package in ("smartdns", "smartdns-ui"):
        if len(re.findall(r"(?m)^define Package/" + package + r"[ \t]*$", text)) != 1:
            raise SystemExit("Selected SmartDNS provider must define " + package)
    luci_text = (luci / "Makefile").read_text(encoding="utf-8")
    if assignment(luci_text, "PKG_NAME") != "luci-app-smartdns" or not re.search(r"\+smartdns(?:[ \t\\]|$)", luci_text):
        raise SystemExit("Selected SmartDNS LuCI must depend on smartdns")
    version = assignment(text, "PKG_VERSION")
    pins = {name: assignment(text, name) for name in ("PKG_SOURCE_VERSION", "SMARTDNS_WEBUI_SOURCE_VERSION")}
    if any(not re.fullmatch(r"[0-9a-f]{40}", value) for value in pins.values()):
        raise SystemExit("Invalid pinned SmartDNS source revision")
    server_hash = assignment(text, "PKG_HASH" if re.search(r"(?m)^PKG_HASH:=", text) else "PKG_MIRROR_HASH")
    if re.search(r"(?m)^SMARTDNS_WEBUI_HASH:=", text):
        web_hash = assignment(text, "SMARTDNS_WEBUI_HASH")
    else:
        downloads = re.findall(r"(?ms)^define Download/smartdns-webui\n(.*?)^endef$", text)
        if len(downloads) != 1:
            raise SystemExit("Missing SmartDNS WebUI download definition")
        web_hash = assignment(downloads[0], "MIRROR_HASH")
    if any(not re.fullmatch(r"[0-9a-f]{64}", value) for value in (server_hash, web_hash)):
        raise SystemExit("Invalid pinned SmartDNS source SHA256")
    return backend, luci, version, pins, server_hash, web_hash

def main():
    mode = sys.argv[1]
    backend, luci, version, pins, server_hash, web_hash = select()
    if mode == "prepare":
        # Validate the complete replacement before removing any duplicate package.
        # Enumerate entries, including dangling aliases left by a feed update.
        for link in Path("package/feeds").glob("*/*"):
            if link.name in ("smartdns", "smartdns-ui", "luci-app-smartdns") and link.is_symlink():
                link.unlink()
        for directory in BACKENDS + LUCIS:
            if directory not in (backend, luci) and directory.exists():
                shutil.rmtree(directory)
    elif mode == "record":
        for directory in BACKENDS + LUCIS:
            if directory not in (backend, luci) and (directory / "Makefile").exists():
                raise SystemExit("Duplicate SmartDNS package definition: " + str(directory))
        for package, directory in (("smartdns", backend), ("luci-app-smartdns", luci)):
            if directory.parts[0] == "feeds":
                feed = directory.parts[1]
                installed = Path("package/feeds") / feed / package / "Makefile"
                if not installed.is_file() or installed.resolve() != (directory / "Makefile").resolve():
                    raise SystemExit("Selected SmartDNS feed package was not installed: " + str(installed))
        with Path("source-versions.txt").open("a", encoding="utf-8") as output:
            output.write("smartdns-provider=" + backend.as_posix() + "\nsmartdns-luci=" + luci.as_posix() + "\n")
            output.write("smartdns-version=" + version + "\n")
            output.write("smartdns=" + pins["PKG_SOURCE_VERSION"] + "\nsmartdns-webui=" + pins["SMARTDNS_WEBUI_SOURCE_VERSION"] + "\n")
            output.write("smartdns-sha256=" + server_hash + "\nsmartdns-webui-sha256=" + web_hash + "\n")
    else:
        raise SystemExit("Unknown SmartDNS preparation mode: " + mode)
    print("SmartDNS " + mode + ": " + str(backend) + " (" + version + "), " + str(luci))

if __name__ == "__main__":
    main()
