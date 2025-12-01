#!/bin/bash
make_result=$(./make_and_test.sh)
make_result_pass=$(echo "$make_result" | grep -oE "Result: PASS" | grep -oE "PASS")
echo "-----"

if [ $make_result_pass = "PASS" ]; then
 ./install_and_run.sh
else
 echo $make_result
fi
