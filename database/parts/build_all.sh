#!/bin/sh
# Rebuilds ../mwave_all.sql from the parts (only needed if you edit a part file).
cd "$(dirname "$0")" && cat 00_reset.sql 01_schema.sql 02_triggers.sql 03_functions.sql 04_views.sql 05_seed.sql 08_security.sql > ../mwave_all.sql
