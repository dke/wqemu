#!/bin/sh
#
#echo "$0" "$@" > netdev-up-bridge1.args
#env > netdev-up-bridge1.env

ifconfig bridge1 addm $1
