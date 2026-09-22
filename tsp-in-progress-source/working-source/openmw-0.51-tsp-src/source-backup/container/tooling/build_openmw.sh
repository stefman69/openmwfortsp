#!/bin/bash
set -e
ldconfig
cd /root/openmw/build
rm -f CMakeCache.txt
cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..
make openmw
