#!/bin/sh
#
# Example host refreshing script.
#

cat <<EOF
{"hostname": "localhost", "address": "127.0.0.1", "port": 4306, "credentials": {"user": "crypt", "password": "crypt"}}
EOF
