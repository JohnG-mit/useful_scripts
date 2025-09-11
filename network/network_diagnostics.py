#!/usr/bin/env python3
"""
Network Diagnostics Tool
Comprehensive network connectivity and performance testing
"""

import subprocess
import socket
import time
import argparse
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed


class NetworkDiagnostics:
    def __init__(self):
        self.results = {}
    
    def ping_host(self, host, count=4, timeout=5):
        """Ping a host and return results"""
        try:
            cmd = ['ping', '-c', str(count), '-W', str(timeout), host]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout*count+10)
            
            if result.returncode == 0:
                lines = result.stdout.split('\n')
                stats_line = [line for line in lines if 'min/avg/max' in line]
                if stats_line:
                    stats = stats_line[0].split('=')[1].strip().split('/')
                    return {
                        'host': host,
                        'status': 'success',
                        'min': float(stats[0]),
                        'avg': float(stats[1]),
                        'max': float(stats[2]),
                        'output': result.stdout
                    }
            
            return {
                'host': host,
                'status': 'failed',
                'error': result.stderr or 'Host unreachable',
                'output': result.stdout
            }
                
        except subprocess.TimeoutExpired:
            return {
                'host': host,
                'status': 'timeout',
                'error': f'Ping timeout after {timeout*count} seconds'
            }
        except Exception as e:
            return {
                'host': host,
                'status': 'error',
                'error': str(e)
            }
    
    def check_port(self, host, port, timeout=5):
        """Check if a specific port is open on a host"""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            start_time = time.time()
            result = sock.connect_ex((host, port))
            end_time = time.time()
            sock.close()
            
            if result == 0:
                return {
                    'host': host,
                    'port': port,
                    'status': 'open',
                    'response_time': round((end_time - start_time) * 1000, 2)
                }
            else:
                return {
                    'host': host,
                    'port': port,
                    'status': 'closed'
                }
        except Exception as e:
            return {
                'host': host,
                'port': port,
                'status': 'error',
                'error': str(e)
            }
    
    def traceroute(self, host, max_hops=30):
        """Perform traceroute to a host"""
        try:
            cmd = ['traceroute', '-m', str(max_hops), host]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            
            return {
                'host': host,
                'status': 'success' if result.returncode == 0 else 'failed',
                'output': result.stdout,
                'error': result.stderr if result.returncode != 0 else None
            }
        except subprocess.TimeoutExpired:
            return {
                'host': host,
                'status': 'timeout',
                'error': 'Traceroute timeout'
            }
        except Exception as e:
            return {
                'host': host,
                'status': 'error',
                'error': str(e)
            }
    
    def dns_lookup(self, hostname):
        """Perform DNS lookup"""
        try:
            start_time = time.time()
            ip_address = socket.gethostbyname(hostname)
            end_time = time.time()
            
            return {
                'hostname': hostname,
                'status': 'success',
                'ip': ip_address,
                'response_time': round((end_time - start_time) * 1000, 2)
            }
        except socket.gaierror as e:
            return {
                'hostname': hostname,
                'status': 'failed',
                'error': str(e)
            }
        except Exception as e:
            return {
                'hostname': hostname,
                'status': 'error',
                'error': str(e)
            }
    
    def get_network_interfaces(self):
        """Get network interface information"""
        try:
            result = subprocess.run(['ip', 'addr', 'show'], capture_output=True, text=True)
            return {
                'status': 'success',
                'output': result.stdout
            }
        except Exception as e:
            return {
                'status': 'error',
                'error': str(e)
            }
    
    def get_routing_table(self):
        """Get routing table"""
        try:
            result = subprocess.run(['ip', 'route', 'show'], capture_output=True, text=True)
            return {
                'status': 'success',
                'output': result.stdout
            }
        except Exception as e:
            return {
                'status': 'error',
                'error': str(e)
            }
    
    def comprehensive_test(self, hosts, ports=None, include_traceroute=False):
        """Run comprehensive network tests"""
        print("=== Network Diagnostics Report ===\n")
        
        # Test network interfaces
        print("1. Network Interfaces:")
        interfaces = self.get_network_interfaces()
        if interfaces['status'] == 'success':
            print(interfaces['output'])
        else:
            print(f"Error: {interfaces['error']}")
        print("-" * 50)
        
        # Test routing table
        print("2. Routing Table:")
        routing = self.get_routing_table()
        if routing['status'] == 'success':
            print(routing['output'])
        else:
            print(f"Error: {routing['error']}")
        print("-" * 50)
        
        # DNS lookups
        print("3. DNS Resolution:")
        with ThreadPoolExecutor(max_workers=5) as executor:
            dns_futures = {executor.submit(self.dns_lookup, host): host for host in hosts}
            
            for future in as_completed(dns_futures):
                result = future.result()
                if result['status'] == 'success':
                    print(f"  {result['hostname']}: {result['ip']} ({result['response_time']}ms)")
                else:
                    print(f"  {result['hostname']}: FAILED ({result['error']})")
        print("-" * 50)
        
        # Ping tests
        print("4. Ping Tests:")
        with ThreadPoolExecutor(max_workers=5) as executor:
            ping_futures = {executor.submit(self.ping_host, host): host for host in hosts}
            
            for future in as_completed(ping_futures):
                result = future.result()
                if result['status'] == 'success':
                    print(f"  {result['host']}: min/avg/max = {result['min']}/{result['avg']}/{result['max']}ms")
                else:
                    print(f"  {result['host']}: FAILED ({result.get('error', 'Unknown error')})")
        print("-" * 50)
        
        # Port scans
        if ports:
            print("5. Port Connectivity:")
            with ThreadPoolExecutor(max_workers=10) as executor:
                port_futures = []
                for host in hosts:
                    for port in ports:
                        port_futures.append(executor.submit(self.check_port, host, port))
                
                for future in as_completed(port_futures):
                    result = future.result()
                    if result['status'] == 'open':
                        print(f"  {result['host']}:{result['port']} - OPEN ({result['response_time']}ms)")
                    elif result['status'] == 'closed':
                        print(f"  {result['host']}:{result['port']} - CLOSED")
                    else:
                        print(f"  {result['host']}:{result['port']} - ERROR ({result.get('error', 'Unknown')})")
            print("-" * 50)
        
        # Traceroute
        if include_traceroute:
            print("6. Traceroute:")
            for host in hosts:
                print(f"\nTraceroute to {host}:")
                result = self.traceroute(host)
                if result['status'] == 'success':
                    print(result['output'])
                else:
                    print(f"  FAILED: {result.get('error', 'Unknown error')}")
            print("-" * 50)


def main():
    parser = argparse.ArgumentParser(description='Network Diagnostics Tool')
    parser.add_argument('hosts', nargs='*', default=['8.8.8.8', 'google.com', 'github.com'],
                        help='Hosts to test (default: 8.8.8.8, google.com, github.com)')
    parser.add_argument('-p', '--ports', nargs='*', type=int,
                        help='Ports to test (e.g., -p 80 443 22)')
    parser.add_argument('-t', '--traceroute', action='store_true',
                        help='Include traceroute in the tests')
    parser.add_argument('--ping-only', action='store_true',
                        help='Only perform ping tests')
    parser.add_argument('--dns-only', action='store_true',
                        help='Only perform DNS lookups')
    
    args = parser.parse_args()
    
    diagnostics = NetworkDiagnostics()
    
    if args.ping_only:
        print("=== Ping Tests ===")
        for host in args.hosts:
            result = diagnostics.ping_host(host)
            if result['status'] == 'success':
                print(f"{result['host']}: min/avg/max = {result['min']}/{result['avg']}/{result['max']}ms")
            else:
                print(f"{result['host']}: FAILED ({result.get('error', 'Unknown error')})")
    
    elif args.dns_only:
        print("=== DNS Lookups ===")
        for host in args.hosts:
            result = diagnostics.dns_lookup(host)
            if result['status'] == 'success':
                print(f"{result['hostname']}: {result['ip']} ({result['response_time']}ms)")
            else:
                print(f"{result['hostname']}: FAILED ({result['error']})")
    
    else:
        diagnostics.comprehensive_test(args.hosts, args.ports, args.traceroute)


if __name__ == "__main__":
    main()