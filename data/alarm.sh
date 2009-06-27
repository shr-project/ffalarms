#!/bin/sh
##ffalarms##

ALSASTATE=%s
REPEAT=%d
ALARM_CMD=%s

ORIG_ALSASTATE=`mktemp /tmp/$0.XXXXXX`
DISPLAY=:0

COPY=
for NAME in `ls x*.ffalarms.* | sed s/^x//`; do
   ps -C "$NAME" > /dev/null && cp "/tmp/$NAME."* "$ORIG_ALSASTATE" \
       && COPY=1 && break
done
[ -n "$COPY" ] || alsactl -f "$ORIG_ALSASTATE" store

SS_TIMEOUT=$(expr "$(xset q -display $DISPLAY)" : ".*timeout:[ ]*\([0-9]\+\)")
if [ -z "$SS_TIMEOUT" ]; then
    SS_TIMEOUT=0
fi

quit() {
        kill $!
        killall -USR1 ffalarms
        wait
        alsactl -f "$ORIG_ALSASTATE" restore
        if [ "$SS_TIMEOUT" -gt 0 ]; then
            xset -display $DISPLAY s "$SS_TIMEOUT"
        fi
        rm -f "x$0.$$" "$ORIG_ALSASTATE"
        exit
}
trap quit TERM

mv "$0" "x$0.$$"

xset -display $DISPLAY s off
xset -display $DISPLAY s reset

alsactl -f "$ALSASTATE" restore

DISPLAY=$DISPLAY ffalarms --puzzle &
ffalarms --play-alarm "$ALARM_CMD" $REPEAT &
wait $!

quit
