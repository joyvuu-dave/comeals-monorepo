# One JSON helper for the deploy scripts. Source it:
#
#   . bin/lib/json.sh
#
# json EXPRESSION reads JSON on stdin, calls it d, and prints the Python
# EXPRESSION. For example: heroku ps -a comeals-staging --json | json "len(d)"
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
