#!/bin/bash

# oracle sniper - setup and monitoring script
# this script sets up the environment and runs the sniper in background

# configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/launch_instance.log"
PID_FILE="${SCRIPT_DIR}/sniper.pid"

# load environment variables
if [ -f "${SCRIPT_DIR}/oci.env" ]; then
    export $(cat "${SCRIPT_DIR}/oci.env" | grep -v '^#' | xargs)
else
    echo "error: oci.env not found"
    exit 1
fi

# check if already running
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p $PID > /dev/null 2>&1; then
        echo "sniper is already running (pid: $PID)"
        echo "use: ./setup_init.sh stop"
        exit 1
    else
        rm -f "$PID_FILE"
    fi
fi

# start sniper
case "$1" in
    start)
        echo "starting oracle sniper..."
        nohup python3 "${SCRIPT_DIR}/main.py" >> "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
        echo "sniper started. logs: $LOG_FILE"
        echo "monitor: tail -f $LOG_FILE"
        ;;
    stop)
        if [ -f "$PID_FILE" ]; then
            PID=$(cat "$PID_FILE")
            kill $PID
            rm -f "$PID_FILE"
            echo "sniper stopped (pid: $PID)"
        else
            echo "sniper is not running"
        fi
        ;;
    status)
        if [ -f "$PID_FILE" ]; then
            PID=$(cat "$PID_FILE")
            if ps -p $PID > /dev/null 2>&1; then
                echo "sniper is running (pid: $PID)"
                tail -10 "$LOG_FILE"
            else
                echo "sniper pid exists but process not found"
            fi
        else
            echo "sniper is not running"
        fi
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    *)
        echo "usage: $0 {start|stop|status|restart}"
        exit 1
        ;;
esac
