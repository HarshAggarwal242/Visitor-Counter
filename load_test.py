"""
Load generator for the Visitor Counter (Windows friendly, standard library only).

Use it to:
    * drive traffic so the Kubernetes HPA scales up,
    * measure requests/second and latency from the laptop,
    * confirm the app keeps answering while Pods scale.

No pip install needed - only modules that ship with Python.

Examples (Windows PowerShell):

    # 30 concurrent visitors for 3 minutes against Docker Compose
    python load_test.py --url http://localhost:8080/ --workers 30 --duration 180

    # Same, against a Minikube service URL
    python load_test.py --url http://127.0.0.1:52000/ --workers 30 --duration 180

While it runs, watch the HPA in a second PowerShell window:
    kubectl get hpa visitor-counter-hpa -w
    kubectl get pods -l app=visitor-counter -w
"""

import argparse
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter


class Stats:
    """Thread-safe counters shared by all worker threads."""

    def __init__(self):
        self.lock = threading.Lock()
        self.total = 0
        self.ok = 0
        self.errors = Counter()
        self.latencies = []  # milliseconds, sampled for percentiles

    def record_ok(self, latency_ms):
        with self.lock:
            self.total += 1
            self.ok += 1
            # Keep memory bounded on very long runs.
            if len(self.latencies) < 200000:
                self.latencies.append(latency_ms)

    def record_error(self, reason):
        with self.lock:
            self.total += 1
            self.errors[reason] += 1

    def snapshot(self):
        with self.lock:
            return self.total, self.ok, Counter(self.errors), len(self.latencies)


def worker(url, deadline, timeout, stats, stop_event):
    """Keep requesting the URL until the deadline or Ctrl+C."""
    while not stop_event.is_set() and time.time() < deadline:
        started = time.perf_counter()
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "visitor-counter-loadtest/1.0"})
            with urllib.request.urlopen(request, timeout=timeout) as response:
                response.read()
                code = response.getcode()
            elapsed_ms = (time.perf_counter() - started) * 1000
            if code == 200:
                stats.record_ok(elapsed_ms)
            else:
                stats.record_error(f"http_{code}")
        except urllib.error.HTTPError as exc:
            stats.record_error(f"http_{exc.code}")
        except urllib.error.URLError as exc:
            stats.record_error(f"network_{type(exc.reason).__name__ if hasattr(exc, 'reason') else 'error'}")
        except Exception as exc:  # noqa: BLE001 - keep the generator alive
            stats.record_error(type(exc).__name__)


def percentile(values, fraction):
    """Simple nearest-rank percentile (values must be a sorted list)."""
    if not values:
        return 0.0
    index = min(len(values) - 1, max(0, int(round(fraction * len(values) + 0.5)) - 1))
    return values[index]


def main():
    parser = argparse.ArgumentParser(description="Simple HTTP load generator for the Visitor Counter.")
    parser.add_argument("--url", default="http://localhost:8080/", help="URL to load (default: %(default)s)")
    parser.add_argument("--workers", type=int, default=20, help="concurrent threads (default: %(default)s)")
    parser.add_argument("--duration", type=int, default=120, help="seconds to run (default: %(default)s)")
    parser.add_argument("--timeout", type=float, default=10.0, help="per-request timeout in seconds")
    parser.add_argument("--interval", type=int, default=10, help="progress print interval in seconds")
    args = parser.parse_args()

    if args.workers < 1 or args.duration < 1:
        print("workers and duration must be positive", file=sys.stderr)
        return 2

    stats = Stats()
    stop_event = threading.Event()
    deadline = time.time() + args.duration

    print(f"Target      : {args.url}")
    print(f"Workers     : {args.workers}")
    print(f"Duration    : {args.duration}s")
    print("Press Ctrl+C to stop early.\n")

    threads = [
        threading.Thread(target=worker, args=(args.url, deadline, args.timeout, stats, stop_event), daemon=True)
        for _ in range(args.workers)
    ]
    started_at = time.time()
    for thread in threads:
        thread.start()

    try:
        while time.time() < deadline and any(t.is_alive() for t in threads):
            time.sleep(min(args.interval, max(0.1, deadline - time.time())))
            total, ok, errors, _ = stats.snapshot()
            elapsed = max(time.time() - started_at, 0.001)
            print(
                f"[{elapsed:6.1f}s] requests={total:7d}  ok={ok:7d}  "
                f"errors={sum(errors.values()):5d}  avg_rate={ok / elapsed:7.1f} req/s"
            )
    except KeyboardInterrupt:
        print("\nCtrl+C received - stopping workers...")
        stop_event.set()

    for thread in threads:
        thread.join(timeout=args.timeout)

    elapsed = max(time.time() - started_at, 0.001)
    total, ok, errors, sampled = stats.snapshot()

    with stats.lock:
        latencies = sorted(stats.latencies)

    print("\n---------------- RESULT ----------------")
    print(f"Wall time      : {elapsed:.1f} s")
    print(f"Requests sent  : {total}")
    print(f"Successful 200 : {ok}")
    print(f"Failed         : {total - ok}")
    print(f"Throughput     : {ok / elapsed:.1f} req/s")
    if latencies:
        print(f"Latency avg    : {sum(latencies) / len(latencies):.1f} ms")
        print(f"Latency p50    : {percentile(latencies, 0.50):.1f} ms")
        print(f"Latency p95    : {percentile(latencies, 0.95):.1f} ms")
        print(f"Latency p99    : {percentile(latencies, 0.99):.1f} ms")
        print(f"Latency max    : {latencies[-1]:.1f} ms")
    if errors:
        print("Error breakdown:")
        for reason, count in errors.most_common():
            print(f"  {reason}: {count}")
    print("----------------------------------------")

    # Non-zero exit code makes scripted checks fail loudly.
    if total == 0 or ok == 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
