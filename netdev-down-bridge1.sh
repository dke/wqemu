#!/bin/sh
#
#echo "$0" "$@" > netdev-down-bridge1.args
#env > netdev-down-bridge1.env

ifconfig bridge1 deletem $1
