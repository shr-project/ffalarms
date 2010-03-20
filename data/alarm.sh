#!/bin/sh
##ffalarms##
%s

REPEAT=%d
ALARM_CMD=%s

DISPLAY=:0

quit() {
        kill $!
        killall -USR1 ffalarms
        wait
        rm -f "x$0.$$"
        exit
}
trap quit TERM

mv "$0" "x$0.$$"

DISPLAY=$DISPLAY sh -c '. /etc/profile; ffalarms --puzzle' &
ffalarms --play-alarm "$ALARM_CMD" $REPEAT &
wait $!

quit
