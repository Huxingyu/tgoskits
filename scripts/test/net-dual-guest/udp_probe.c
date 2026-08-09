// Minimal UDP probe for the task-2 dual-guest network smoke test.
//
// The task-2 initramfs busybox has ifconfig/ping/route but no `nc`, so this
// small static tool is used to prove bidirectional UDP between Linux and the
// RTOS-side guest.
//
// Usage:
//   udp_probe recv <port>
//   udp_probe send <ip> <port> <count> [interval_ms] [tag]
//
// `recv` replies with "ACK <rest>" for every payload starting with "PING ",
// which makes the pcap capture show a bidirectional exchange.

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static int parse_port(const char *s, uint16_t *out) {
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end == s || *end != '\0' || v < 1 || v > 65535) {
        fprintf(stderr, "invalid port: %s\n", s);
        return -1;
    }
    *out = (uint16_t)v;
    return 0;
}

static int parse_u32(const char *s, uint32_t *out) {
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end == s || *end != '\0' || v < 0) {
        fprintf(stderr, "invalid number: %s\n", s);
        return -1;
    }
    *out = (uint32_t)v;
    return 0;
}

static int run_recv(uint16_t port) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_ANY),
        .sin_port = htons(port),
    };
    if (bind(fd, (const struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(fd);
        return 1;
    }

    printf("udp_probe: recv on 0.0.0.0:%u\n", (unsigned)port);
    fflush(stdout);

    while (!g_stop) {
        char buf[1500];
        struct sockaddr_in src;
        socklen_t src_len = sizeof(src);
        ssize_t n = recvfrom(fd, buf, sizeof(buf) - 1, 0,
                             (struct sockaddr *)&src, &src_len);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("recvfrom");
            break;
        }
        buf[n] = '\0';
        char ip[INET_ADDRSTRLEN] = "?";
        inet_ntop(AF_INET, &src.sin_addr, ip, sizeof(ip));
        printf("[%llu ms] recv %zd bytes from %s:%u: %s\n",
               (unsigned long long)now_ms(), n, ip,
               (unsigned)ntohs(src.sin_port), buf);
        fflush(stdout);

        if (n >= 5 && memcmp(buf, "PING ", 5) == 0) {
            char reply[1500];
            int rlen = snprintf(reply, sizeof(reply), "ACK %s", buf + 5);
            if (rlen > 0) {
                ssize_t sent = sendto(fd, reply, (size_t)rlen, 0,
                                      (const struct sockaddr *)&src, src_len);
                if (sent < 0) {
                    perror("sendto ACK");
                }
            }
        }
    }

    close(fd);
    return 0;
}

static int run_send(const char *ip, uint16_t port, uint32_t count,
                    uint32_t interval_ms, const char *tag) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
    };
    if (inet_pton(AF_INET, ip, &dst.sin_addr) != 1) {
        fprintf(stderr, "invalid IPv4 address: %s\n", ip);
        close(fd);
        return 1;
    }

    // Wait up to 500 ms for the ACK of each datagram; the receiver replies
    // immediately, so this is generous for a local p2p link.
    struct timeval rcv_timeout = {
        .tv_sec = 0,
        .tv_usec = 500 * 1000,
    };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv_timeout, sizeof(rcv_timeout));

    printf("udp_probe: send %u packets to %s:%u every %u ms (tag=%s)\n",
           (unsigned)count, ip, (unsigned)port, (unsigned)interval_ms, tag);
    fflush(stdout);

    uint32_t acked = 0;
    uint64_t rtt_min = UINT64_MAX, rtt_max = 0, rtt_sum = 0;

    for (uint32_t i = 0; i < count && !g_stop; i++) {
        char payload[1500];
        uint64_t sent_ts = now_ms();
        int plen = snprintf(payload, sizeof(payload), "PING %u %s %llu", i,
                            tag, (unsigned long long)sent_ts);
        ssize_t sent = sendto(fd, payload, (size_t)plen, 0,
                              (const struct sockaddr *)&dst, sizeof(dst));
        if (sent < 0) {
            perror("sendto");
            break;
        }
        printf("[%llu ms] sent %zd bytes: %s\n",
               (unsigned long long)sent_ts, sent, payload);
        fflush(stdout);

        // Wait for the matching ACK before the next send. A stale ACK from a
        // previous packet is ignored (only the sequence number counts).
        uint64_t deadline = sent_ts + 500;
        while (!g_stop && now_ms() < deadline) {
            int64_t remain = (int64_t)(deadline - now_ms());
            if (remain <= 0) {
                break;
            }
            struct pollfd pfd = {.fd = fd, .events = POLLIN};
            int pr = poll(&pfd, 1, (int)remain);
            if (pr < 0) {
                if (errno == EINTR) {
                    continue;
                }
                perror("poll");
                break;
            }
            if (pr == 0) {
                break;
            }

            char buf[1500];
            ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
            if (n < 0) {
                if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue;
                }
                perror("recv ACK");
                break;
            }
            buf[n] = '\0';
            if (n < 5 || memcmp(buf, "ACK ", 4) != 0) {
                continue;
            }
            unsigned long seq = strtoul(buf + 4, NULL, 10);
            if ((uint32_t)seq != i) {
                continue;
            }
            uint64_t rtt = now_ms() - sent_ts;
            if (rtt < rtt_min) {
                rtt_min = rtt;
            }
            if (rtt > rtt_max) {
                rtt_max = rtt;
            }
            rtt_sum += rtt;
            acked++;
            printf("[%llu ms] ack %u rtt=%llu ms: %s\n",
                   (unsigned long long)now_ms(), (unsigned)i,
                   (unsigned long long)rtt, buf);
            fflush(stdout);
            break;
        }

        if (interval_ms > 0) {
            struct timespec req = {
                .tv_sec = (time_t)(interval_ms / 1000),
                .tv_nsec = (long)(interval_ms % 1000) * 1000000L,
            };
            while (nanosleep(&req, &req) < 0 && errno == EINTR && !g_stop) {
            }
        }
    }

    if (count > 0) {
        double rate = 100.0 * (double)acked / (double)count;
        printf("udp_probe: send summary sent=%u acked=%u rate=%.2f%% "
               "rtt_min=%llu rtt_avg=%llu rtt_max=%llu ms\n",
               (unsigned)count, (unsigned)acked, rate,
               (unsigned long long)(acked ? rtt_min : 0),
               (unsigned long long)(acked ? rtt_sum / acked : 0),
               (unsigned long long)rtt_max);
    }

    close(fd);
    return 0;
}

int main(int argc, char **argv) {
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (argc >= 3 && strcmp(argv[1], "recv") == 0) {
        uint16_t port = 0;
        if (parse_port(argv[2], &port) < 0) {
            return 2;
        }
        return run_recv(port);
    }

    if (argc >= 5 && strcmp(argv[1], "send") == 0) {
        uint16_t port = 0;
        uint32_t count = 0;
        uint32_t interval_ms = 1000;
        const char *tag = "probe";
        if (parse_port(argv[3], &port) < 0 || parse_u32(argv[4], &count) < 0) {
            return 2;
        }
        if (argc >= 6 && parse_u32(argv[5], &interval_ms) < 0) {
            return 2;
        }
        if (argc >= 7) {
            tag = argv[6];
        }
        return run_send(argv[2], port, count, interval_ms, tag);
    }

    fprintf(stderr,
            "usage:\n"
            "  %s recv <port>\n"
            "  %s send <ip> <port> <count> [interval_ms] [tag]\n",
            argv[0], argv[0]);
    return 2;
}
