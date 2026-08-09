// Task-2 Linux guest init: fix the initramfs console device nodes, bring up
// the NIC when present, start the UDP probe, and keep PID 1 alive.
//
// The stock initramfs ships /dev/console as a regular file; the kernel opens
// it for init's fds 0/1/2 before the script runs, so shell output disappears
// into that file. A static C init replaces it with a real char device first.

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <unistd.h>

static void make_dev(const char *path, unsigned major, unsigned minor) {
    unlink(path);
    if (mknod(path, S_IFCHR | 0600, makedev(major, minor)) != 0) {
        // Keep whatever exists; the console may already be a device node.
    }
}

static void say(const char *s) {
    int fd = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (fd >= 0) {
        write(fd, s, strlen(s));
        write(fd, "\n", 1);
        close(fd);
    }
}

int main(void) {
    make_dev("/dev/console", 5, 1);
    make_dev("/dev/null", 1, 3);
    make_dev("/dev/kmsg", 1, 11);

    int con = open("/dev/console", O_RDWR | O_NOCTTY);
    if (con >= 0) {
        dup2(con, 0);
        dup2(con, 1);
        dup2(con, 2);
        if (con > 2) {
            close(con);
        }
    }

    say("TASK2_INIT_START");

    if (access("/sys/class/net/eth0", F_OK) == 0) {
        int rc = system("ifconfig eth0 10.0.42.1 netmask 255.255.255.0 up");
        char buf[64];
        int len = snprintf(buf, sizeof(buf), "TASK2_IFCONFIG_RC=%d", rc);
        write(1, buf, (size_t)len);
        write(1, "\n", 1);
    } else {
        say("TASK2_NO_ETH0");
    }

    system("udp_probe recv 4242 &");
    say("TASK2_UDP_RECV_STARTED");

    for (;;) {
        pause();
    }
}
