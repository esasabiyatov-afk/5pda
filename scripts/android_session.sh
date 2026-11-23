#!/usr/bin/env bash
# Сеанс в эмуляторе Android: официальный клиент 4PDA управляется командами из
# файла android/cmd.txt ветки; снимки экрана и разметка публикуются
# (зашифрованными) в релиз android-session.
set -u
BRANCH="${GITHUB_REF_NAME}"
REL=android-session
PKG=ru.fourpda.client
WORK=$(mktemp -d)
LAST=0
DEADLINE=$(( $(date +%s) + ${SESSION_MINUTES:-50} * 60 ))

openssl enc -d -aes-256-cbc -pbkdf2 -in android/4pda.apk.enc -out "$WORK/4pda.apk" -pass env:APK_KEY || { echo "APK_KEY неверный"; exit 1; }
adb install -r -g "$WORK/4pda.apk"
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null
sleep 8

publish() {  # $1 — номер шага
  local d="$WORK/out"; rm -rf "$d"; mkdir -p "$d"
  adb exec-out screencap -p > "$d/screen.png"
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 && adb pull /sdcard/ui.xml "$d/ui.xml" >/dev/null 2>&1
  adb shell dumpsys activity activities 2>/dev/null | grep -m3 -E "mResumedActivity|topResumedActivity" > "$d/activity.txt"
  echo "$1" > "$d/step.txt"
  (cd "$d" && zip -q ../state.zip *)
  openssl rand -out "$WORK/key.bin" 32
  openssl enc -aes-256-cbc -pbkdf2 -salt -in "$WORK/state.zip" -out "$WORK/state.zip.enc" -pass file:"$WORK/key.bin"
  openssl pkeyutl -encrypt -pubin -inkey scripts/probe.pub -pkeyopt rsa_padding_mode:oaep -in "$WORK/key.bin" -out "$WORK/state.key.enc"
  echo "$1" > "$WORK/step.txt"
  gh release upload $REL "$WORK/state.zip.enc" "$WORK/state.key.enc" --clobber >/dev/null
  gh release upload $REL "$WORK/step.txt" --clobber >/dev/null   # последним: сигнал готовности
  rm -f "$WORK/state.zip" "$WORK/key.bin"
}

run_cmd() {
  local verb="$1"; shift
  case "$verb" in
    tap) adb shell input tap "$1" "$2" ;;
    long) adb shell input swipe "$1" "$2" "$1" "$2" 900 ;;
    swipe) adb shell input swipe "$1" "$2" "$3" "$4" "${5:-300}" ;;
    text) adb shell input text "$(echo "$*" | sed 's/ /%s/g')" ;;
    secret) # secret login|password — вводит значение секрета, не показывая его
      local v=""; [ "$1" = login ] && v="$PDA_LOGIN"; [ "$1" = password ] && v="$PDA_PASSWORD"
      adb shell input text "$(printf '%s' "$v" | sed 's/ /%s/g')" ;;
    key) adb shell input keyevent "$1" ;;
    back) adb shell input keyevent 4 ;;
    wait) sleep "$1" ;;
    launch) adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null ;;
    restart) adb shell am force-stop $PKG; adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null ;;
    end) exit 0 ;;
    *) echo "неизвестная команда $verb" ;;
  esac
}

publish 0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 4
  git fetch -q origin "$BRANCH" 2>/dev/null || continue
  CMDS=$(git show FETCH_HEAD:android/cmd.txt 2>/dev/null) || continue
  # Формат: строки «<шаг> <команда> [аргументы]»; выполняются шаги больше последнего.
  NEW=$(echo "$CMDS" | awk -v l="$LAST" '$1+0 > l+0')
  [ -z "$NEW" ] && continue
  STEP=$LAST
  while read -r n verb args; do
    [ -z "${n:-}" ] && continue
    echo "шаг $n: $verb $([ "$verb" = secret ] && echo '***' || echo "$args")"
    # shellcheck disable=SC2086
    run_cmd "$verb" $args
    sleep 0.7
    STEP=$n
  done <<< "$NEW"
  LAST=$STEP
  sleep 1.5
  publish "$LAST"
done
