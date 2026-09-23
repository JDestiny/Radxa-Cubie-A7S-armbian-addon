#!/usr/bin/env python3
"""
CPU Performance Benchmark Tool v1.0
Supports single-core / multi-core / big.LITTLE multi-dimensional benchmarks
Auto-detects heterogeneous core topology, independently reports different core types
"""

import time
import math
import hashlib
import random
import sys
import os
import platform
import subprocess
import statistics
import multiprocessing
from concurrent.futures import ProcessPoolExecutor, as_completed
from collections import OrderedDict

# ───────────────────────── Config ─────────────────────────
SINGLE_CORE_DURATION = 5        # seconds per single-core test
PER_CORE_PROBE_DURATION = 3     # seconds per round in per-core probe
PROBE_ROUNDS = 3                # probe rounds (median used)
PROBE_WARMUP = 0.5              # warmup seconds before probe
PRIME_LIMIT = 100_000           # sieve upper limit
MATRIX_SIZE = 200               # matrix multiplication dimension
FFT_SIZE = 2 ** 18              # FFT size
HASH_BYTES = 10_000_000         # hash throughput test data size
COMPRESS_BYTES = 5_000_000      # compression test data size
SORT_SIZE = 2_000_000          # number of elements to sort
PI_DIGITS_TERMS = 5000          # terms for pi calculation


# ───────────────────────── Utilities ─────────────────────────
def fmt(n):
    """Format large numbers"""
    if n >= 1_000_000:
        return f"{n/1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n/1_000:.2f}K"
    return f"{n:.2f}"


def bar(pct, width=30):
    filled = int(width * min(pct, 100) / 100)
    return f"[{'█' * filled}{'░' * (width - filled)}] {pct:5.1f}%"


def header(title):
    w = 60
    print(f"\n{'═' * w}")
    print(f"  {title}")
    print(f"{'═' * w}")


# ───────────────────── Core Topology Detection ─────────────────────
def detect_core_topology():
    """
    Get CPU big.LITTLE topology from OS (best-effort).
    Supports macOS (Apple Silicon / Intel) and Linux (Intel Hybrid / ARM big.LITTLE)
    """
    info = {
        'total': multiprocessing.cpu_count(),
        'heterogeneous': False,
    }
    system = platform.system()

    if system == 'Darwin':
        def _sysctl(key):
            try:
                return subprocess.check_output(
                    ['sysctl', '-n', key],
                    stderr=subprocess.DEVNULL,
                ).decode().strip()
            except Exception:
                return None

        p_str = _sysctl('hw.perflevel0.logicalcpu')
        e_str = _sysctl('hw.perflevel1.logicalcpu')
        if p_str and e_str:
            info['p_cores'] = int(p_str)
            info['e_cores'] = int(e_str)
            info['heterogeneous'] = True

        chip = _sysctl('machdep.cpu.brand_string')
        if chip:
            info['chip'] = chip

    elif system == 'Linux':
        try:
            freqs = []
            for i in range(info['total']):
                path = f'/sys/devices/system/cpu/cpu{i}/cpufreq/cpuinfo_max_freq'
                if os.path.exists(path):
                    with open(path) as f:
                        freqs.append((i, int(f.read().strip())))
            if freqs:
                max_freq = max(f for _, f in freqs)
                min_freq = min(f for _, f in freqs)
                if max_freq / max(min_freq, 1) > 1.2:
                    threshold = (max_freq + min_freq) / 2
                    p_cores = [cpu for cpu, f in freqs if f > threshold]
                    e_cores = [cpu for cpu, f in freqs if f <= threshold]
                    info['p_cores'] = len(p_cores)
                    info['e_cores'] = len(e_cores)
                    info['p_core_ids'] = p_cores
                    info['e_core_ids'] = e_cores
                    info['heterogeneous'] = True
                    info['p_max_freq_mhz'] = max_freq / 1000
                    info['e_max_freq_mhz'] = min_freq / 1000
        except Exception:
            pass

        try:
            with open('/proc/cpuinfo') as f:
                for line in f:
                    if line.startswith('model name'):
                        info['chip'] = line.split(':', 1)[1].strip()
                        break
        except Exception:
            pass

    return info


# ───────────────────── 单项测试函数 ─────────────────────

def bench_prime_sieve(limit=PRIME_LIMIT):
    """Eratosthenes prime sieve — integer ops"""
    sieve = bytearray(b'\x01') * (limit + 1)
    sieve[0] = sieve[1] = 0
    for i in range(2, int(limit ** 0.5) + 1):
        if sieve[i]:
            sieve[i*i::i] = bytearray(len(sieve[i*i::i]))
    return sum(sieve)


def bench_matrix_mul(n=MATRIX_SIZE):
    """Pure Python n×n matrix multiplication — floating point ops"""
    rng = random.Random(42)
    A = [[rng.random() for _ in range(n)] for _ in range(n)]
    B = [[rng.random() for _ in range(n)] for _ in range(n)]
    C = [[0.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(n):
            s = 0.0
            for k in range(n):
                s += A[i][k] * B[k][j]
            C[i][j] = s
    return C[0][0]


def bench_fft(n=FFT_SIZE):
    """Radix-2 Cooley-Tukey FFT — floating point ops"""
    rng = random.Random(123)
    real = [rng.random() for _ in range(n)]
    imag = [0.0] * n
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            real[i], real[j] = real[j], real[i]
            imag[i], imag[j] = imag[j], imag[i]
    length = 2
    while length <= n:
        half = length // 2
        angle = -2.0 * math.pi / length
        wr, wi = math.cos(angle), math.sin(angle)
        for start in range(0, n, length):
            cur_r, cur_i = 1.0, 0.0
            for k in range(half):
                a = start + k
                b = a + half
                tr = cur_r * real[b] - cur_i * imag[b]
                ti = cur_r * imag[b] + cur_i * real[b]
                real[b] = real[a] - tr
                imag[b] = imag[a] - ti
                real[a] += tr
                imag[a] += ti
                cur_r, cur_i = cur_r * wr - cur_i * wi, cur_r * wi + cur_i * wr
        length <<= 1
    return real[0]


def bench_hash(size=HASH_BYTES):
    """SHA-256 hash throughput"""
    data = os.urandom(size)
    h = hashlib.sha256(data).hexdigest()
    return h


def bench_sort(size=SORT_SIZE):
    """Large array sorting"""
    rng = random.Random(99)
    arr = [rng.random() for _ in range(size)]
    arr.sort()
    return arr[-1]


def bench_fibonacci(n=38):
    """Recursive Fibonacci (no memo, pure recursion stress test)"""
    def fib(x):
        if x < 2:
            return x
        return fib(x - 1) + fib(x - 2)
    return fib(n)


def bench_pi(terms=PI_DIGITS_TERMS):
    """Bailey-Borwein-Plouffe formula for pi"""
    pi = 0.0
    power = 1.0
    for k in range(terms):
        pi += (1.0 / power) * (
            4.0 / (8 * k + 1) -
            2.0 / (8 * k + 4) -
            1.0 / (8 * k + 5) -
            1.0 / (8 * k + 6)
        )
        power *= 16.0
    return pi


def bench_compress(size=COMPRESS_BYTES):
    """zlib compression"""
    import zlib
    data = os.urandom(size)
    compressed = zlib.compress(data, 6)
    return len(compressed)


# ───────────── Benchmark Registry ─────────────
BENCHMARKS = OrderedDict([
    ("Integer (Prime Sieve)",    bench_prime_sieve),
    ("Float (Matrix Mul)",       bench_matrix_mul),
    ("Float (FFT)",              bench_fft),
    ("Hash (SHA-256)",           bench_hash),
    ("Memory Sort",              bench_sort),
    ("Recursion (Fibonacci)",   bench_fibonacci),
    ("Math (Pi)",                bench_pi),
    ("Compress (zlib)",          bench_compress),
])

# Lightweight benchmarks for per-core probe
PROBE_BENCHMARKS = OrderedDict([
    ("Integer", bench_prime_sieve),
    ("Float", bench_pi),
])

# Scoring reference values
REFERENCE = {
    "Integer (Prime Sieve)":    80,
    "Float (Matrix Mul)":        0.5,
    "Float (FFT)":               3,
    "Hash (SHA-256)":           15,
    "Memory Sort":              3,
    "Recursion (Fibonacci)":    3,
    "Math (Pi)":                200,
    "Compress (zlib)":          5,
}


# ──────────── Worker Functions (subprocess) ──────────────
def _try_set_affinity(cpu_id):
    """Try to pin current process to specified CPU core (Linux only)"""
    try:
        os.sched_setaffinity(0, {cpu_id})
        return True
    except (AttributeError, OSError):
        return False


def _worker_fixed(func, iterations):
    """Run fixed iterations of benchmark in subprocess"""
    for _ in range(iterations):
        func()
    return iterations


def _worker_timed(func, duration):
    """Run benchmark for fixed duration in subprocess, return (iterations, elapsed)"""
    count = 0
    t0 = time.perf_counter()
    deadline = t0 + duration
    while time.perf_counter() < deadline:
        func()
        count += 1
    elapsed = time.perf_counter() - t0
    return (count, elapsed)


def _worker_probe(func, duration, warmup, cpu_id=None):
    """
    Per-core probe worker:
    1. Optional pin (Linux)
    2. Warmup phase (not counted)
    3. Timed run
    Returns (cpu_id, iterations, elapsed, pinned)
    """
    pinned = False
    if cpu_id is not None:
        pinned = _try_set_affinity(cpu_id)
    # 预热
    t_warm = time.perf_counter() + warmup
    while time.perf_counter() < t_warm:
        func()
    # 正式测试
    count = 0
    t0 = time.perf_counter()
    deadline = t0 + duration
    while time.perf_counter() < deadline:
        func()
        count += 1
    elapsed = time.perf_counter() - t0
    return (cpu_id, count, elapsed, pinned)


# ───────────── Core Classification ─────────────
def _otsu_threshold(values):
    """
    Otsu threshold method (max inter-class variance) splits ordered values into two groups.
    Returns best split index (first split_idx+1 elements as big cores).
    """
    n = len(values)
    if n < 2:
        return 0
    total_sum = sum(values)
    total_n = n
    best_var = -1
    best_idx = 0
    sum_bg = 0.0
    n_bg = 0
    for i in range(n - 1):
        n_bg += 1
        n_fg = total_n - n_bg
        sum_bg += values[i]
        sum_fg = total_sum - sum_bg
        mean_bg = sum_bg / n_bg
        mean_fg = sum_fg / n_fg
        var_between = n_bg * n_fg * (mean_bg - mean_fg) ** 2
        if var_between > best_var:
            best_var = var_between
            best_idx = i
    return best_idx


def classify_cores(ops_list, topology_hint=None):
    """
    Multi-strategy core classification:
    1. If system reports big/LITTLE counts (topology_hint), use those and verify
    2. Otherwise use Otsu + max gap dual verification
    Returns None if cores are homogeneous.
    """
    if len(ops_list) < 2:
        return None

    indexed = sorted(enumerate(ops_list), key=lambda x: x[1], reverse=True)
    sorted_ops = [v for _, v in indexed]
    sorted_idx = [i for i, _ in indexed]

    ratio = sorted_ops[0] / max(sorted_ops[-1], 1e-9)
    if ratio < 1.25:
        return None  # 算力差异太小

    split_idx = None

    # 策略 1: 系统拓扑提示 (Apple Silicon / Linux hybrid)
    if topology_hint and topology_hint.get('heterogeneous'):
        p_count = topology_hint.get('p_cores')
        if p_count and 0 < p_count < len(ops_list):
            # 按系统报告的大核数量分割
            candidate_split = p_count - 1
            # 验证: 两组均值差异需 > 15%
            big_part = sorted_ops[:candidate_split + 1]
            little_part = sorted_ops[candidate_split + 1:]
            if little_part:
                cand_ratio = statistics.mean(big_part) / max(statistics.mean(little_part), 1e-9)
                if cand_ratio > 1.15:
                    split_idx = candidate_split

    # 策略 2: Otsu 最大类间方差 + 最大间隔 交叉验证
    if split_idx is None:
        # Otsu 法
        otsu_idx = _otsu_threshold(sorted_ops)

        # 最大间隔法
        gaps = []
        for i in range(len(sorted_ops) - 1):
            # 使用相对间隔 (归一化) 避免绝对值偏差
            rel_gap = (sorted_ops[i] - sorted_ops[i + 1]) / max(sorted_ops[i], 1e-9)
            gaps.append((rel_gap, i))
        maxgap_idx = max(gaps, key=lambda x: x[0])[1]

        # 两种方法一致 -> 高置信度
        if otsu_idx == maxgap_idx:
            split_idx = otsu_idx
        else:
            # 不一致时取间隔更大的那个分割点
            gap_at_otsu = sorted_ops[otsu_idx] - sorted_ops[otsu_idx + 1] if otsu_idx + 1 < len(sorted_ops) else 0
            gap_at_maxgap = sorted_ops[maxgap_idx] - sorted_ops[maxgap_idx + 1] if maxgap_idx + 1 < len(sorted_ops) else 0
            split_idx = otsu_idx if gap_at_otsu >= gap_at_maxgap else maxgap_idx

        # 最终验证: 分割后两组均值比必须 > 1.2
        big_part = sorted_ops[:split_idx + 1]
        little_part = sorted_ops[split_idx + 1:]
        if not little_part:
            return None
        final_ratio = statistics.mean(big_part) / max(statistics.mean(little_part), 1e-9)
        if final_ratio < 1.2:
            return None

    big_indices = sorted_idx[:split_idx + 1]
    little_indices = sorted_idx[split_idx + 1:]
    big_ops = sorted_ops[:split_idx + 1]
    little_ops = sorted_ops[split_idx + 1:]

    return {
        'big_count': len(big_ops),
        'little_count': len(little_ops),
        'big_indices': sorted(big_indices),
        'little_indices': sorted(little_indices),
        'big_ops': big_ops,
        'little_ops': little_ops,
        'big_avg': statistics.mean(big_ops),
        'little_avg': statistics.mean(little_ops),
        'ratio': statistics.mean(big_ops) / max(statistics.mean(little_ops), 1e-9),
    }


# ───────────── Single Core Benchmark ─────────────
def run_single_core():
    header("Single Core Benchmark (Fastest Core)")
    results = {}
    total = len(BENCHMARKS)
    for idx, (name, func) in enumerate(BENCHMARKS.items(), 1):
        print(f"\n  [{idx}/{total}] {name} ... ", end="", flush=True)
        func()  # warmup
        count = 0
        t0 = time.perf_counter()
        deadline = t0 + SINGLE_CORE_DURATION
        while time.perf_counter() < deadline:
            func()
            count += 1
        elapsed = time.perf_counter() - t0
        ops_sec = count / elapsed
        results[name] = {
            "iterations": count,
            "elapsed": elapsed,
            "ops_sec": ops_sec,
        }
        print(f"{count} iters / {elapsed:.2f}s  ({ops_sec:.2f} ops/s)")
    return results


# ───────────── Per-Core Power Probe ─────────────
def run_per_core_probe(topology):
    """
    Precise per-core power probe:
    1. On Linux, pin workers (sched_setaffinity) so each runs on a specific core
    2. On macOS, launch N workers and let scheduler distribute naturally
    3. Multi-round probing with median to eliminate scheduling jitter
    4. Each worker includes warmup phase
    5. Multiple benchmarks cross-validate with system topology hints
    """
    cores = topology['total']
    can_pin = hasattr(os, 'sched_setaffinity')  # Linux support

    header(f"Per-Core Power Probe  ({cores} logical cores)")

    if topology.get('heterogeneous'):
        p = topology.get('p_cores', '?')
        e = topology.get('e_cores', '?')
        print(f"\n  System reports: {p} P-cores + {e} E-cores")
    else:
        print(f"\n  System reports no heterogeneous topology, probing empirically")

    pin_str = "pinned mode" if can_pin else "scheduler mode"
    print(f"  {PROBE_ROUNDS} rounds x {PER_CORE_PROBE_DURATION}s/round, "
          f"warmup {PROBE_WARMUP}s, {pin_str}, {cores} workers\n")

    probe_results = {}

    for test_name, func in PROBE_BENCHMARKS.items():
        print(f"  Probing {test_name} ({PROBE_ROUNDS} rounds):", flush=True)

        rounds_data = []

        for rnd in range(PROBE_ROUNDS):
            print(f"    Round {rnd+1}/{PROBE_ROUNDS} ... ", end="", flush=True)

            with ProcessPoolExecutor(max_workers=cores) as pool:
                futures = {}
                for cpu_id in range(cores):
                    pin_id = cpu_id if can_pin else None
                    fut = pool.submit(
                        _worker_probe, func,
                        PER_CORE_PROBE_DURATION, PROBE_WARMUP,
                        pin_id
                    )
                    futures[fut] = cpu_id

                core_ops = [0.0] * cores
                pinned_any = False
                for fut in as_completed(futures):
                    core_idx = futures[fut]
                    returned_cpu_id, count, elapsed, pinned = fut.result()
                    core_ops[core_idx] = count / elapsed
                    if pinned:
                        pinned_any = True

            rounds_data.append(core_ops)

            mx, mn = max(core_ops), min(core_ops)
            print(f"max {mx:.1f}  min {mn:.1f}  ratio {mx/max(mn,1e-9):.2f}x"
                  f"{'  pinned' if pinned_any else ''}")

        median_ops = []
        for c in range(cores):
            vals = [rounds_data[r][c] for r in range(PROBE_ROUNDS)]
            median_ops.append(statistics.median(vals))

        probe_results[test_name] = median_ops
        max_ops = max(median_ops)

        print(f"\n    Median results ({PROBE_ROUNDS} rounds):")
        sorted_indices = sorted(range(cores), key=lambda i: median_ops[i], reverse=True)
        for i in sorted_indices:
            ops = median_ops[i]
            pct = ops / max_ops * 100
            print(f"    Core {i:>2d}: {ops:>10.2f} ops/s  {bar(pct, 20)}")

        classification = classify_cores(median_ops, topology)
        if classification:
            print(f"\n    -> Heterogeneity detected: {classification['big_count']} big cores "
                  f"(avg {classification['big_avg']:.1f} ops/s) + "
                  f"{classification['little_count']} little cores "
                  f"(avg {classification['little_avg']:.1f} ops/s)  "
                  f"ratio {classification['ratio']:.2f}x")
        else:
            print(f"\n    -> All cores uniform, no big/little difference")
        print()

    # ── Cross-validate multiple benchmarks ──
    classifications = []
    for test_name in PROBE_BENCHMARKS:
        cls = classify_cores(probe_results[test_name], topology)
        if cls:
            classifications.append(cls)

    if len(probe_results) > 1:
        combined_scores = [0.0] * cores
        for test_name in PROBE_BENCHMARKS:
            ops = probe_results[test_name]
            mx = max(ops) if max(ops) > 0 else 1
            for c in range(cores):
                combined_scores[c] += ops[c] / mx
        final_classification = classify_cores(combined_scores, topology)
    else:
        primary_ops = probe_results[list(PROBE_BENCHMARKS.keys())[0]]
        final_classification = classify_cores(primary_ops, topology)

    if final_classification and len(classifications) >= 2:
        counts_agree = all(
            c['big_count'] == classifications[0]['big_count']
            for c in classifications
        )
        if counts_agree:
            print(f"  Multi-benchmark cross-validation agrees: {classifications[0]['big_count']} big + {classifications[0]['little_count']} little")
        else:
            print(f"  Multi-benchmark classification differs, using combined score")
    elif final_classification:
        print(f"  Final classification: {final_classification['big_count']} big + {final_classification['little_count']} little")
    else:
        print(f"  Final classification: homogeneous cores (no big/little)")

    return {
        'probe_results': probe_results,
        'classification': final_classification,
        'per_core_ops': probe_results[list(PROBE_BENCHMARKS.keys())[0]],
    }


# ────────────── Big/Little Independent Multi-Dimensional Test ──────────────
def run_hetero_benchmark(probe_info):
    """
    Run full benchmarks separately for big and little cores:
      - Big core group (workers = big core count)
      - Little core group (workers = little core count)
      - Full mixed (all cores)
    """
    cls = probe_info['classification']
    if not cls:
        return None

    big_n = cls['big_count']
    little_n = cls['little_count']
    total_n = big_n + little_n

    header(f"Big/Little Independent Benchmark  ({big_n} big + {little_n} little)")
    print(f"\n  Three phases: big({big_n} threads) / little({little_n} threads) / mixed({total_n} threads)\n")

    hetero_all_results = {}
    total = len(BENCHMARKS)

    for idx, (name, func) in enumerate(BENCHMARKS.items(), 1):
        print(f"  [{idx}/{total}] {name}")

        test_result = {}

        for label, n_workers in [("Big", big_n), ("Little", little_n), ("Mixed", total_n)]:
            with ProcessPoolExecutor(max_workers=n_workers) as pool:
                futs = [pool.submit(_worker_timed, func, 2.0) for _ in range(n_workers)]
                worker_results = [f.result() for f in as_completed(futs)]

            ops_list = [cnt / max(elapsed, 1e-9) for cnt, elapsed in worker_results]
            total_iters = sum(cnt for cnt, _ in worker_results)
            total_time = sum(elapsed for _, elapsed in worker_results)
            throughput = sum(ops_list)
            avg_ops = throughput / n_workers if n_workers else 0
            min_ops = min(ops_list) if ops_list else 0
            max_ops = max(ops_list) if ops_list else 0

            test_result[label] = {
                'workers': n_workers,
                'total_iters': total_iters,
                'elapsed_sum': total_time,
                'throughput': throughput,
                'avg_ops': avg_ops,
                'min_ops': min_ops,
                'max_ops': max_ops,
                'ops_list': ops_list,
            }
            print(f"    {label:<8} ({n_workers:>2} threads): "
                  f"iters {total_iters:>6} | throughput {throughput:.2f} ops/s | "
                  f"per-core min/avg/max: {min_ops:.2f}/{avg_ops:.2f}/{max_ops:.2f}")

        single_count, single_elapsed = _worker_timed(func, 2.0)
        single_throughput = single_count / single_elapsed

        for label in ["Big", "Little", "Mixed"]:
            r = test_result[label]
            r['speedup'] = r['throughput'] / max(single_throughput, 1e-9)
            r['efficiency'] = r['speedup'] / max(r['workers'], 1) * 100

        test_result['single_throughput'] = single_throughput
        hetero_all_results[name] = test_result

        big_sp = test_result['Big']['speedup']
        little_sp = test_result['Little']['speedup']
        full_sp = test_result['Mixed']['speedup']
        print(f"    Speedup:  big {big_sp:.2f}x  little {little_sp:.2f}x  mixed {full_sp:.2f}x")

        big_eff = test_result['Big']['efficiency']
        little_eff = test_result['Little']['efficiency']
        full_eff = test_result['Mixed']['efficiency']
        print(f"    Efficiency: big {big_eff:.1f}%  little {little_eff:.1f}%  mixed {full_eff:.1f}%")

        for label in ["Big", "Little", "Mixed"]:
            r = test_result[label]
            print(f"      {label} per-core min/avg/max: {r['min_ops']:.2f}/{r['avg_ops']:.2f}/{r['max_ops']:.2f} ops/s")
        print()

    return hetero_all_results


# ─────────── Homogeneous Multi-Core Benchmark ───────────
def run_multi_core_homogeneous():
    cores = multiprocessing.cpu_count()
    header(f"Multi-Core Benchmark  (Homogeneous {cores} cores)")
    results = {}
    total = len(BENCHMARKS)

    for idx, (name, func) in enumerate(BENCHMARKS.items(), 1):
        print(f"\n  [{idx}/{total}] {name}")
        t0 = time.perf_counter()
        func()
        single_time = time.perf_counter() - t0
        iters_per_core = max(1, int(3.0 / max(single_time, 1e-9)))

        t_start = time.perf_counter()
        with ProcessPoolExecutor(max_workers=cores) as pool:
            futures = [pool.submit(_worker_fixed, func, iters_per_core) for _ in range(cores)]
            done = sum(f.result() for f in as_completed(futures))
        t_total = time.perf_counter() - t_start

        t_single_start = time.perf_counter()
        for _ in range(iters_per_core):
            func()
        t_single = time.perf_counter() - t_single_start

        speedup = (t_single * cores) / t_total if t_total > 0 else 0
        efficiency = speedup / cores * 100

        results[name] = {
            "cores": cores,
            "total_iters": done,
            "multi_time": t_total,
            "single_time_equiv": t_single * cores,
            "speedup": speedup,
            "efficiency": efficiency,
        }
        print(f"    Single-core baseline: {t_single:.2f}s x {cores} = {t_single*cores:.2f}s")
        print(f"    Multi-core actual: {t_total:.2f}s  (total iters {done})")
        print(f"    Speedup:   {speedup:.2f}x   Efficiency: {bar(efficiency)}")

    return results


# ───────────── Score Report ─────────────
def _geomean(arr):
    return math.exp(sum(math.log(max(s, 1)) for s in arr) / len(arr))


def compute_scores_homogeneous(single_results, multi_results):
    """Homogeneous core scoring"""
    header("Score Report (Homogeneous Cores)")

    print(f"\n  {'Test':<26} {'Single ops/s':>12} {'Single score':>10} {'Efficiency':>10} {'Multi score':>10}")
    print(f"  {'─' * 70}")

    single_scores = []
    multi_scores = []

    for name in BENCHMARKS:
        ops = single_results[name]["ops_sec"]
        ref = REFERENCE.get(name, 1)
        sc_single = min(ops / ref * 1000, 99999)
        sc_multi = sc_single * multi_results[name]["speedup"]
        eff = multi_results[name]["efficiency"]

        single_scores.append(sc_single)
        multi_scores.append(sc_multi)

        print(f"  {name:<26} {ops:>12.2f} {sc_single:>10.0f} {eff:>9.1f}% {sc_multi:>10.0f}")

    geo_single = _geomean(single_scores)
    geo_multi = _geomean(multi_scores)

    print(f"  {'─' * 70}")
    print(f"  {'Single-core geomean':.<40} {geo_single:>10.0f}")
    print(f"  {'Multi-core geomean':.<40} {geo_multi:>10.0f}")
    print(f"  {'Multi/Single ratio':.<40} {geo_multi/geo_single:>10.2f}x")
    print()
    return geo_single, geo_multi


def compute_scores_heterogeneous(single_results, hetero_results, probe_info):
    """Heterogeneous big/little core scoring"""
    cls = probe_info['classification']
    big_n = cls['big_count']
    little_n = cls['little_count']

    header(f"Score Report (Heterogeneous: {big_n} big + {little_n} little)")

    print(f"\n  {'Test':<22} {'Single':>8} {'Big':>10} {'Little':>10} {'Mixed':>10} {'Big eff':>8} {'Little eff':>8}")
    print(f"  {'─' * 80}")

    single_scores = []
    big_scores = []
    little_scores = []
    full_scores = []

    for name in BENCHMARKS:
        ops = single_results[name]["ops_sec"]
        ref = REFERENCE.get(name, 1)
        sc_single = min(ops / ref * 1000, 99999)

        hr = hetero_results[name]
        big_tp = hr['Big']['throughput']
        little_tp = hr['Little']['throughput']
        full_tp = hr['Mixed']['throughput']
        big_eff = hr['Big']['efficiency']
        little_eff = hr['Little']['efficiency']

        sc_big = min(big_tp / ref * 1000, 99999)
        sc_little = min(little_tp / ref * 1000, 99999)
        sc_full = min(full_tp / ref * 1000, 99999)

        single_scores.append(sc_single)
        big_scores.append(sc_big)
        little_scores.append(sc_little)
        full_scores.append(sc_full)

        print(f"  {name:<22} {sc_single:>8.0f} {sc_big:>10.0f} {sc_little:>10.0f} "
              f"{sc_full:>10.0f} {big_eff:>7.1f}% {little_eff:>7.1f}%")

    geo_single = _geomean(single_scores)
    geo_big = _geomean(big_scores)
    geo_little = _geomean(little_scores)
    geo_full = _geomean(full_scores)

    print(f"  {'─' * 80}")
    print(f"  {'Single geomean':.<34} {geo_single:>8.0f}")
    print(f"  {'Big group geomean':.<34} {geo_big:>10.0f}")
    print(f"  {'Little group geomean':.<34} {geo_little:>10.0f}")
    print(f"  {'Mixed geomean':.<34} {geo_full:>10.0f}")

    # ── Big/Little power comparison ──
    header("Big/Little Power Comparison")
    print(f"\n  Big/Little power ratio (from per-core probe): {cls['ratio']:.2f}x")
    print(f"  Big avg ops/s: {cls['big_avg']:.2f}")
    print(f"  Little avg ops/s: {cls['little_avg']:.2f}")

    big_total_power = cls['big_avg'] * big_n
    little_total_power = cls['little_avg'] * little_n
    combined = big_total_power + little_total_power
    big_pct = big_total_power / combined * 100
    little_pct = little_total_power / combined * 100

    print(f"\n  Power composition:")
    print(f"    Big ({big_n} cores): {bar(big_pct, 30)}  {big_pct:.1f}%")
    print(f"    Little ({little_n} cores): {bar(little_pct, 30)}  {little_pct:.1f}%")

    if cls['big_avg'] > 0:
        equiv = combined / cls['big_avg']
        print(f"\n  Equivalent big cores: {equiv:.1f} (little cores converted to big power)")

    print(f"\n  {'═' * 50}")
    print(f"  Single score:       {geo_single:>10.0f}  (fastest core)")
    print(f"  Big group score:    {geo_big:>10.0f}  (big cores only)")
    print(f"  Little group score: {geo_little:>10.0f}  (little cores only)")
    print(f"  Mixed score:        {geo_full:>10.0f}  (big+little mixed)")
    print(f"  Mixed / Single:     {geo_full/geo_single:>10.2f}x")
    print(f"  {'═' * 50}")
    print()

    return geo_single, geo_full


# ───────────── System Info ─────────────
def show_system_info(topology):
    header("System Info")
    uname = platform.uname()
    print(f"  OS:            {uname.system} {uname.release} ({uname.machine})")
    chip = topology.get('chip', platform.processor() or uname.machine)
    print(f"  Processor:     {chip}")
    print(f"  Logical cores: {topology['total']}")

    if topology.get('heterogeneous'):
        p = topology.get('p_cores', '?')
        e = topology.get('e_cores', '?')
        print(f"  Core topology: {p} P-cores + {e} E-cores  [heterogeneous]")
    else:
        print(f"  Core topology: {topology['total']} cores [homogeneous / unprobed]")

    if 'p_max_freq_mhz' in topology:
        print(f"  P-core max freq: {topology['p_max_freq_mhz']:.0f} MHz")
        print(f"  E-core max freq: {topology['e_max_freq_mhz']:.0f} MHz")

    print(f"  Python:        {platform.python_version()} ({platform.python_implementation()})")
    print(f"  Test time:     {time.strftime('%Y-%m-%d %H:%M:%S')}")


# ───────────── Main ─────────────
def main():
    print("""
    ╔══════════════════════════════════════════════════╗
    ║      CPU Performance Benchmark Tool v1.0         ║
    ║   Single · Multi-Core · Big/LITTLE Benchmark    ║
    ║   Auto-detects heterogeneous cores              ║
    ╚══════════════════════════════════════════════════╝
    """)

    # 1. Detect core topology
    topology = detect_core_topology()
    show_system_info(topology)

    print(f"\n  Single-core {SINGLE_CORE_DURATION}s/test | Per-core {PROBE_ROUNDS}rounds x {PER_CORE_PROBE_DURATION}s "
          f"| {len(BENCHMARKS)} dimensions\n")

    # 2. Single-core performance
    single_results = run_single_core()

    # 3. Per-core power probe (detect big/little)
    probe_info = run_per_core_probe(topology)

    # 4. Choose test path based on heterogeneity
    is_hetero = probe_info['classification'] is not None

    if is_hetero:
        cls = probe_info['classification']
        if not topology.get('heterogeneous'):
            print(f"\n  System didn't report heterogeneous, but probe found "
                  f"{cls['big_count']} big + {cls['little_count']} little "
                  f"(ratio {cls['ratio']:.2f}x)")

        hetero_results = run_hetero_benchmark(probe_info)
        compute_scores_heterogeneous(single_results, hetero_results, probe_info)
    else:
        if topology.get('heterogeneous'):
            print(f"\n  System reports heterogeneous, but all cores similar, treating as homogeneous")
        multi_results = run_multi_core_homogeneous()
        compute_scores_homogeneous(single_results, multi_results)

    print("  Benchmark complete!\n")


if __name__ == "__main__":
    multiprocessing.freeze_support()
    main()
