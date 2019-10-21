#!/bin/sh

sudo ifconfig bridge2 172.16.0.1/16
sudo sysctl -w net.inet.ip.forwarding=1
sudo pfctl -F all
sudo pfctl -f /Users/de/Documents/Devel/Qemu/pf.conf -e
sudo brew services restart --verbose dnsmasq

