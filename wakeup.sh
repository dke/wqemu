#!/bin/sh

if ! ifconfig bridge2 | grep -q "inet 172.16.0.1 "
then
    echo ifconfig bridge2 172.16.0.1/16
    sudo ifconfig bridge2 172.16.0.1/16
else
    echo bridge2 already got IP 172.16.0.1, doing nothing.
fi

for c in $( ifconfig | sed -ne 's/^\(tap[0-9]*[13579]\).*/\1/p' )
do
    if ! echo "$( ifconfig bridge2 | sed -ne 's/.*member: \(tap[0-9]*[13579]\).*/\1/p' )" | grep -q $c
    then
        echo ifconfig bridge2 addm $c
        sudo ifconfig bridge2 addm $c
    else
        echo bridge2 already members interface $c, doing nothing.
    fi
done

