"""Генерирует source.json для SideStore/AltStore.

Берёт прошлый source.json из последнего релиза (если есть), добавляет новую версию в начало списка.
Аргументы: repo tag ipa_path version build_number
"""
import datetime
import json
import os
import sys
import urllib.request

repo, tag, ipa_path, version, build = sys.argv[1:6]
base = f"https://github.com/{repo}/releases"
ipa_name = os.path.basename(ipa_path)
bundle_id = "com.fivepda.client"
icon = f"{base}/latest/download/icon.png"

old_versions = []
try:
    with urllib.request.urlopen(f"{base}/latest/download/source.json", timeout=20) as r:
        old = json.load(r)
    for app in old.get("apps", []):
        if app.get("bundleIdentifier") == bundle_id:
            old_versions = [v for v in app.get("versions", []) if v.get("version") != version]
except Exception as e:
    print("no previous source.json:", e)

notes = os.environ.get("RELEASE_NOTES", "").strip() or "Новая сборка."
new_version = {
    "version": version,
    "buildVersion": build,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": notes,
    "downloadURL": f"{base}/download/{tag}/{ipa_name}",
    "size": os.path.getsize(ipa_path),
    "minOSVersion": "16.0",
}

source = {
    "name": "5PDA",
    "identifier": "com.fivepda.source",
    "subtitle": "Неофициальный клиент 4PDA для iOS",
    "description": "Источник обновлений 5PDA — неофициального клиента форума 4PDA.",
    "iconURL": icon,
    "website": f"https://github.com/{repo}",
    "tintColor": "4A5BE8",
    "featuredApps": [bundle_id],
    "apps": [
        {
            "name": "5PDA",
            "bundleIdentifier": bundle_id,
            "developerName": "5PDA",
            "subtitle": "Неофициальный клиент 4PDA",
            "localizedDescription": "Новости, форум, темы и вход в аккаунт 4PDA. Работает по протоколу официального Android-клиента.",
            "iconURL": icon,
            "tintColor": "4A5BE8",
            "category": "social",
            "screenshotURLs": [],
            "versions": [new_version] + old_versions[:19],
            "appPermissions": {"entitlements": [], "privacy": {}},
        }
    ],
    "news": [],
}

with open("source.json", "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
print(json.dumps(new_version, ensure_ascii=False, indent=2))
