#!/system/bin/sh
# priority guard: keep render-path processes fed, keep helper processes off big cores.
(
  while true; do
    # 1) GMS family -> background cpuset (small cores 0-2)
    for pid in $(pidof com.google.android.gms com.google.android.gms.persistent com.google.process.gapps com.google.android.gms.ui com.google.android.gms.unstable com.google.android.gms.persistent 2>/dev/null); do
      echo $pid > /dev/cpuset/background/tasks 2>/dev/null
    done
    # 2) Alipay helper processes (NOT main) -> background cpuset
    for pid in $(pidof com.eg.android.AlipayGphone:push com.eg.android.AlipayGphone:widgetProvider com.eg.android.AlipayGphone:sandboxed_privilege_process0 com.eg.android.AlipayGphone:tools 2>/dev/null); do
      echo $pid > /dev/cpuset/background/tasks 2>/dev/null
    done
    # 3) SystemUI render priority (idempotent renice)
    ui=$(pidof com.android.systemui)
    [ -n "$ui" ] && renice -n -10 -p $ui >/dev/null 2>&1
    # 4) Xiaomi push storm containment: xmsf family sits in foreground
    #    cpu group (shares 5120) -- move to background (shares 1024)
    #    + nice +10 so bursts cap at ~1/5 of a foreground app.
    #    Push delivery itself is network-wait, unaffected.
    for pid in $(pidof com.xiaomi.xmsf com.xiaomi.xmsf:services com.xiaomi.xmsfkeeper 2>/dev/null); do
      echo $pid > /dev/cpuctl/background/tasks 2>/dev/null
      renice -n 10 -p $pid >/dev/null 2>&1
    done
    sleep 30
  done
) &
