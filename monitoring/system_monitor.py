#!/usr/bin/env python3
"""
System Monitor - Real-time system resource monitoring
Monitors CPU, memory, disk usage, and network statistics
"""

import psutil
import time
import argparse
from datetime import datetime


def get_size(bytes, suffix="B"):
    """Convert bytes to human readable format"""
    factor = 1024
    for unit in ["", "K", "M", "G", "T", "P"]:
        if bytes < factor:
            return f"{bytes:.2f}{unit}{suffix}"
        bytes /= factor


def monitor_system(interval=1, duration=None):
    """Monitor system resources"""
    print("=== System Resource Monitor ===")
    print("Press Ctrl+C to stop\n")
    
    start_time = time.time()
    
    try:
        while True:
            # Current timestamp
            print(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            
            # CPU Information
            print("CPU Usage:")
            print(f"  Overall: {psutil.cpu_percent(interval=1)}%")
            cpu_per_core = psutil.cpu_percent(percpu=True)
            for i, percentage in enumerate(cpu_per_core):
                print(f"  Core {i}: {percentage}%")
            
            # Memory Information
            memory = psutil.virtual_memory()
            print(f"\nMemory Usage:")
            print(f"  Total: {get_size(memory.total)}")
            print(f"  Available: {get_size(memory.available)}")
            print(f"  Used: {get_size(memory.used)} ({memory.percent}%)")
            
            # Disk Information
            print(f"\nDisk Usage:")
            partitions = psutil.disk_partitions()
            for partition in partitions:
                try:
                    partition_usage = psutil.disk_usage(partition.mountpoint)
                    print(f"  {partition.device} ({partition.mountpoint}):")
                    print(f"    Total: {get_size(partition_usage.total)}")
                    print(f"    Used: {get_size(partition_usage.used)} ({partition_usage.percent}%)")
                    print(f"    Free: {get_size(partition_usage.free)}")
                except PermissionError:
                    print(f"  {partition.device}: Permission denied")
            
            # Network Information
            net_io = psutil.net_io_counters()
            print(f"\nNetwork I/O:")
            print(f"  Bytes Sent: {get_size(net_io.bytes_sent)}")
            print(f"  Bytes Received: {get_size(net_io.bytes_recv)}")
            
            # Load Average (Unix systems)
            try:
                load = psutil.getloadavg()
                print(f"\nLoad Average: {load[0]:.2f}, {load[1]:.2f}, {load[2]:.2f}")
            except AttributeError:
                pass  # Not available on Windows
            
            print("-" * 50)
            
            # Check duration
            if duration and (time.time() - start_time) >= duration:
                break
                
            time.sleep(interval)
            
    except KeyboardInterrupt:
        print("\nMonitoring stopped.")


def main():
    parser = argparse.ArgumentParser(description='Monitor system resources')
    parser.add_argument('-i', '--interval', type=int, default=5,
                        help='Monitoring interval in seconds (default: 5)')
    parser.add_argument('-d', '--duration', type=int,
                        help='Duration to monitor in seconds (default: unlimited)')
    
    args = parser.parse_args()
    monitor_system(args.interval, args.duration)


if __name__ == "__main__":
    main()