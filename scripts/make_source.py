"""Генерирует source.json для SideStore/AltStore.

Берёт прошлый source.json из последнего релиза (если есть), добавляет новую версию в начало списка.
Аргументы: repo tag ipa_path version build_number [ipa_x_path]
В источнике два приложения: 5PDA и мод 5PDA X (если передан второй IPA).
"""
import datetime
import json
import os
import sys
import urllib.request

repo, tag, ipa_path, version, build = sys.argv[1:6]
ipa_x_path = sys.argv[6] if len(sys.argv) > 6 else None
base = f"https://github.com/{repo}/releases"
bundle_id = "com.fivepda.client"
bundle_x = "com.fivepda.client.x"
icon = f"{base}/latest/download/icon.png"
icon_x = f"{base}/latest/download/icon-x.png"

old_apps = {}
try:
    with urllib.request.urlopen(f"{base}/latest/download/source.json", timeout=20) as r:
        old = json.load(r)
    for app in old.get("apps", []):
        old_apps[app.get("bundleIdentifier")] = [v for v in app.get("versions", []) if v.get("version") != version]
except Exception as e:
    print("no previous source.json:", e)

raw_notes = os.environ.get("RELEASE_NOTES", "")
notes = "\n".join(
    line for line in raw_notes.splitlines()
    if not line.startswith(("Co-Authored-By:", "Claude-Session:", "Signed-off-by:"))
).strip() or "Новая сборка."
def make_version(path):
    return {
        "version": version,
        "buildVersion": build,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": notes,
        "downloadURL": f"{base}/download/{tag}/{os.path.basename(path)}",
        "size": os.path.getsize(path),
        "minOSVersion": "16.0",
    }

new_version = make_version(ipa_path)

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
            "versions": [new_version] + old_apps.get(bundle_id, [])[:19],
            "appPermissions": {"entitlements": [], "privacy": {}},
        }
    ] + ([
        {
            "name": "5PDA X",
            "bundleIdentifier": bundle_x,
            "developerName": "5PDA",
            "subtitle": "Мод 5PDA с интерфейсом для iOS",
            "localizedDescription": "Тот же клиент 4PDA, но с интерфейсом, удобным для iPhone. Ставится рядом с обычным 5PDA.",
            "iconURL": icon_x,
            "tintColor": "FF9500",
            "category": "social",
            "screenshotURLs": [],
            "versions": [make_version(ipa_x_path)] + old_apps.get(bundle_x, [])[:19],
            "appPermissions": {"entitlements": [], "privacy": {}},
        }
    ] if ipa_x_path else []),
    "news": [],
}

with open("source.json", "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
print(json.dumps(new_version, ensure_ascii=False, indent=2))
