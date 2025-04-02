#!/bin/sh -eu

psql <<EOF
	CREATE USER golem WITH PASSWORD '12345';
	CREATE DATABASE blockscout WITH OWNER golem;
	CREATE DATABASE stats WITH OWNER golem;
EOF
