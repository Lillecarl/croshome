#!@shell@
# /init of the nested VM: report every input device and every event on the
# serial console, one line each, with the device's bus type. 0003 is USB,
# 0006 virtio, 0011 i8042 (PS/2).
#
# @shell@, @path@ and @modules@ are substituted at build time.
export PATH=@path@
mkdir -p /proc /sys /dev /tmp
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
for m in @modules@; do
  modprobe "$m" || echo "MODPROBE-FAILED $m"
done

watch() {
  dev=/sys/class/input/$1/device
  bus=$(cat "$dev/id/bustype")
  echo "WATCH $1 bus=$bus name=$(cat "$dev/name")"
  exec 3<"/dev/input/$1"
  # One struct input_event (24 bytes) per read: 8 shorts of time, then
  # type, code and the low and high halves of value.
  while ev=$(dd bs=24 count=1 <&3 2>/dev/null | od -An -v -t d2) && [ -n "$ev" ]; do
    # shellcheck disable=SC2086
    set -- $ev
    [ "$9" = 0 ] && continue
    echo "EV bus=$bus type=$9 code=${10} value=${11}"
  done
  echo "GONE $1"
}

first=1
while true; do
  for d in /sys/class/input/event*; do
    n=${d##*/}
    [ -e "$d" ] && [ ! -e "/tmp/$n" ] || continue
    touch "/tmp/$n"
    watch "$n" &
  done
  [ -n "$first" ] && echo READY && first=
  sleep 0.2
done
