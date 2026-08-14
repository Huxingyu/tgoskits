#!/bin/sh
# RT-partition Linux measurement init.
#
# Runs inside the Linux guest initramfs. Controlled by kernel cmdline
# placeholders replaced by run-cyclictest.sh via the `cmdline` field:
#   rt_scenario=idle|stress-noiso|stress-rt
#   rt_cpu=N            measurement vCPU (default 0)
#   rt_loops=N          cyclictest loop count (default 1800000 = 30 min at 1 ms)
#   rt_interval_us=N    cyclictest interval (default 1000)
#   rt_maxlat_us=N      histogram max latency (default 400)
#   rt_priority=N       cyclictest SCHED_FIFO priority (default 90)
#
# The measurement task is pinned to the isolated vCPU (guest CPU 0 by
# default) so kernel timers and IRQ affinity (irqaffinity=0) do not compete
# with the sampler; guest CPU 1 stays isolated via isolcpus.

set -u

/bin/busybox rm -f /dev/console /dev/null
/bin/busybox mknod -m 0600 /dev/console c 5 1
/bin/busybox mknod -m 0666 /dev/null c 1 3
exec </dev/console >/dev/console 2>&1

/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mkdir -p /tmp

scenario=idle
cpu=0
loops=1800000
interval_us=1000
maxlat_us=400
priority=90

for arg in $(cat /proc/cmdline); do
    case "$arg" in
        rt_scenario=*) scenario="${arg#rt_scenario=}" ;;
        rt_cpu=*) cpu="${arg#rt_cpu=}" ;;
        rt_loops=*) loops="${arg#rt_loops=}" ;;
        rt_interval_us=*) interval_us="${arg#rt_interval_us=}" ;;
        rt_maxlat_us=*) maxlat_us="${arg#rt_maxlat_us=}" ;;
        rt_priority=*) priority="${arg#rt_priority=}" ;;
    esac
done

echo "RT_INIT scenario=$scenario cpu=$cpu loops=$loops interval_us=$interval_us maxlat_us=$maxlat_us priority=$priority"
echo "RT_CPUS total=$(/bin/busybox grep -c ^processor /proc/cpuinfo)"

# Record a load snapshot every 5 s during the run (task2-style markers are
# not used here; the console log is the evidence).
/bin/busybox top -b -d 5 > /tmp/rt-top.log &

case "$scenario" in
    stress-noiso)
        echo "RT_STRESS_START workers=2 vm=1"
        /bin/stress-ng --taskset "$cpu" --cpu 2 --vm 1 --vm-bytes 64M &
        stress_pid=$!
        ;;
    stress-rt)
        echo "RT_STRESS_START workers=2 vm=1"
        /bin/stress-ng --taskset "$cpu" --cpu 2 --vm 1 --vm-bytes 64M &
        stress_pid=$!
        ;;
esac

echo "RT_CYCLICTEST_START"
/bin/cyclictest -a "$cpu" \
    -m -p "$priority" -i "$interval_us" -l "$loops" -h "$maxlat_us" -q
echo "RT_CYCLICTEST_COMPLETE"

if [ -n "${stress_pid:-}" ]; then
    /bin/busybox kill "$stress_pid" 2>/dev/null || true
fi
/bin/busybox kill %1 2>/dev/null || true

# Keep the console alive briefly so the runner can capture the tail.
/bin/busybox sleep 2
echo "RT_INIT_DONE scenario=$scenario"
poweroff -f 2>/dev/null || /bin/busybox sleep 30
