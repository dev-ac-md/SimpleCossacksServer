#!/bin/bash
kill $(sudo netstat -nlp | grep :34001 | grep -oE "[0-9]*\/" | grep -oE "[0-9]*")
