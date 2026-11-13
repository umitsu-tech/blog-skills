#!/bin/sh
echo "PROBE_OK args=[$*]"
if [ "$1" = "--log" ]; then echo "STDIN=[$(cat)]"; fi
